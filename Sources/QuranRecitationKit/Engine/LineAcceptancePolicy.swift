import Foundation

/// Model scheduling only; this never creates lexical/acoustic evidence. Keep
/// the three real endpoint checkpoints needed by muqattaat stability, then one
/// terminal observation. Legacy cached-analysis ticks still run before this gate.
struct SilenceInferenceGate: Sendable {
    private var lastVoiceOutputSample: Int64?
    private var lastCheckpoint = -1

    mutating func shouldRun(lastVoice: Int64, trailingSilence: Int) -> Bool {
        let minimum = LineAcceptancePolicy.minimumTrailingSilenceSampleCount
        let stride = LineAcceptancePolicy.minimumFreshSampleCount
        let checkpoint: Int
        if trailingSilence > LineAcceptancePolicy.maximumTrailingSilenceSampleCount {
            checkpoint = 4
        } else if trailingSilence >= minimum {
            checkpoint = min(3, 1 + (trailingSilence - minimum) / stride)
        } else {
            checkpoint = 0
        }
        if lastVoiceOutputSample != lastVoice {
            lastVoiceOutputSample = lastVoice
            lastCheckpoint = checkpoint
            return true
        }
        guard checkpoint > lastCheckpoint else { return false }
        lastCheckpoint = checkpoint
        return true
    }
}

/// A scorer's decision about whether the acoustic frames favor the requested
/// Quran line over nearby/confusable Quran text by the named uncalibrated
/// identity heuristic.
///
/// The  never manufactures this evidence from a transcript percentage.
/// Until a scorer can make a real decision, the result stays `inconclusive`
/// and the policy may publish provisional word coverage but cannot accept the
/// line or award growth. Identity alone does not prove completion.
enum AcousticDecision: Equatable, Sendable {
    case identityMatched
    case inconclusive
    case rejected
}

/// The identity-backed evidence surfaced to the  for one inference
/// cycle. All word indices are ayah-relative and zero-based.  is a
/// welcoming recitation experience, not a tajweed grader: the acoustic Quran
/// identity and ordered word evidence remain mandatory, while ordinary speech
/// pace and presentation-only token wobble must not force repeat performances.
struct LineEvidence: Equatable, Sendable {
    let progress: InternalLineProgress
    let matchedLineWordIndices: Set<Int>
    let requiredMatchedWordCount: Int
    let contiguousPrefixWordCount: Int
    let requiredPrefixWordCount: Int
    let stableCycleCount: Int
    let requiredStableCycleCount: Int
    let speechSpanSampleCount: Int
    let minimumSpeechSpanSampleCount: Int
    let freshSampleCount: Int
    let minimumFreshSampleCount: Int
    let trailingSilenceSampleCount: Int
    let minimumTrailingSilenceSampleCount: Int
    let maximumTrailingSilenceSampleCount: Int
    let lastVoiceOutputSample: Int64
    /// True only when this exact fresh observation passed every content,
    /// endpoint, sample-domain, and acoustic gate before cycle-counting.
    let currentCycleQualifies: Bool
    /// True when this exact fresh observation passes every gate except trailing
    /// silence. The service may retain that analysis under an exact voice fence
    /// and reevaluate it only at subsequently captured sample-domain ticks.
    let contentAndAcousticQualifyIgnoringSilence: Bool
    /// Current-snapshot terminal-word evidence. This is one component of the
    /// user-authorized completion heuristic, not calibrated endpoint proof.
    let endpointMatched: Bool
    let acousticDecision: AcousticDecision
    /// True only when the identity heuristic matched this window and at least
    /// one contiguous expected word is present.
    let isIdentityMatchedPartial: Bool
    /// Durable coverage emitted only after every heuristic gate repeats for
    /// the required number of cycles. This is not a zero-FAR claim.
    let acceptedWordCount: Int
    let isAccepted: Bool
}

/// Immutable identity for reusing one analysis that passed every non-silence
/// completion gate across later sample-domain stability ticks. Every field must
/// remain exact; new voice, target, or capture generation requires fresh ONNX.
struct VoiceMarkerFence: Equatable, Sendable {
    let generation: UInt64
    let voiceEpoch: UInt64
    let lastVoiceOutputSample: Int64
}

struct ReusableInferenceKey: Equatable, Sendable {
    let voiceFence: VoiceMarkerFence
    let sessionID: UUID
}

enum ReusableInferencePolicy {
    static func canReuse(
        cachedKey: ReusableInferenceKey,
        requestedKey: ReusableInferenceKey,
        trailingSilenceSampleCount: Int
    ) -> Bool {
        cachedKey == requestedKey
            && (0...LineAcceptancePolicy
                .maximumTrailingSilenceSampleCount)
                .contains(trailingSilenceSampleCount)
    }
}

/// Conservative display-only policy for a current-word retry cue. It cannot
/// accept a line and deliberately refuses rejected/inconclusive whole-line
/// audio so wrong Quran text and noise remain neutral rather than accusatory.
enum CurrentWordPronunciationCuePolicy {
    static let requiredStableAnalysisCount = 2

    static func shouldSignalNeedsRetry(
        acousticDecision: AcousticDecision,
        currentWordFraction: Double,
        divergentTokenID: Int?,
        stableAnalysisCount: Int,
        candidateFenceMatches: Bool
    ) -> Bool {
        acousticDecision == .identityMatched
            && currentWordFraction.isFinite
            && currentWordFraction > 0
            && currentWordFraction < 1
            && divergentTokenID != nil
            && stableAnalysisCount >= requiredStableAnalysisCount
            && candidateFenceMatches
    }
}

/// Reconstructs only stability ticks for silence samples that were actually
/// captured while one exact voice-marker fence remained live. It never creates
/// acoustic or word evidence; callers must reuse a fully qualifying model
/// analysis and revalidate the fence before committing policy mutation.
enum TerminalStabilityTickPlanner {
    static func additionalTrailingSilenceTicks(
        after analyzedTrailingSilenceSampleCount: Int,
        through capturedTrailingSilenceSampleCount: Int,
        sampleStride: Int = LineAcceptancePolicy.minimumFreshSampleCount
    ) -> [Int] {
        guard sampleStride > 0 else { return [] }
        let analyzed = max(0, analyzedTrailingSilenceSampleCount)
        let captured = min(
            max(0, capturedTrailingSilenceSampleCount),
            LineAcceptancePolicy.maximumTrailingSilenceSampleCount
        )
        guard captured > analyzed else { return [] }

        var ticks: [Int] = []
        var next = analyzed
        while true {
            let (candidate, overflowed) = next.addingReportingOverflow(sampleStride)
            guard !overflowed, candidate <= captured else { break }
            if LineAcceptancePolicy.trailingSilenceSampleRange
                .contains(candidate) {
                ticks.append(candidate)
            }
            next = candidate
        }
        return ticks
    }
}

/// Deterministic acceptance policy for a single  display line.
///
/// This intentionally has no generic "similarity percent" gate. The expected
/// line must beat distinct Quran confusers by the named
/// uncalibrated identity margin. Completion is then inferred from current
/// decoder coverage, an exact sample-domain speech-span floor, 400...2,000 ms of
/// trailing silence, and an unchanged absolute last-voice marker across
/// repeated fresh cycles. This intentionally does not claim calibrated or
/// zero-false-advance behavior.
struct LineAcceptancePolicy: Sendable {
    static let minimumFreshSampleCount = 3_200
    static let minimumTrailingSilenceSampleCount = 6_400
    // A 1,024-frame input tap can quantize successful 3,200-sample-fresh
    // snapshots to roughly 6,144-sample intervals. Ordinary MainActor jitter
    // can widen a retained interval further, so the 2,000 ms ceiling keeps a
    // three-snapshot run inside the acceptance window without forcing the
    // normal path to wait for that ceiling.
    static let maximumTrailingSilenceSampleCount = 32_000
    static let trailingSilenceSampleRange =
        minimumTrailingSilenceSampleCount...maximumTrailingSilenceSampleCount

    private let lineWordRange: Range<Int>
    private let silenceRange: ClosedRange<Int>
    private let minimumRequiredSpeechSpanSampleCount: Int
    private let minimumStableCycleCount: Int
    private var lastFreshSequence: UInt64?
    private var stableLastVoiceOutputSample: Int64?
    private(set) var stableCycleCount = 0
    private(set) var hasAccepted = false

    init(
        lineWordRange: Range<Int>,
        standaloneMuqattaatForm: MuqattaatForm? = nil,
        minimumTrailingSilenceSamples: Int = Self.minimumTrailingSilenceSampleCount,
        requiredStableCycles: Int = 1
    ) {
        self.lineWordRange = lineWordRange
        silenceRange = max(3200, min(32000, minimumTrailingSilenceSamples))...Self.maximumTrailingSilenceSampleCount
        minimumRequiredSpeechSpanSampleCount = standaloneMuqattaatForm.map {
            Self.minimumSpeechSpanSampleCount(for: $0.spokenLetterCount)
        } ?? Self.minimumOrdinarySpeechSpanSampleCount(for: lineWordRange.count)
        // A disconnected-letter target can be emitted by CTC before its full
        // pronunciation finishes. Keep all three current-snapshot, silence,
        // identity, and marker-stability cycles even for the longer forms.
        minimumStableCycleCount = max(requiredStableCycles, standaloneMuqattaatForm == nil ? 1 : 3)
    }

    mutating func reset() {
        lastFreshSequence = nil
        stableLastVoiceOutputSample = nil
        stableCycleCount = 0
        hasAccepted = false
    }

    /// Records a fresh current-marker snapshot that has no decoder-supported
    /// focus word. This breaks any prior stability run without constructing or
    /// publishing a fake first-word `InternalLineProgress` value.
    mutating func observeEmptyFreshCycle(
        sequence: UInt64,
        isFreshCycle: Bool
    ) {
        guard registerFreshSequence(sequence, isFreshCycle: isFreshCycle) else {
            return
        }
        stableLastVoiceOutputSample = nil
        stableCycleCount = 0
    }

    mutating func evaluate(
        progress: InternalLineProgress,
        matchedLineWordIndices: Set<Int>,
        sequence: UInt64,
        isFreshCycle: Bool,
        freshSampleCount: Int,
        speechSpanSampleCount: Int,
        trailingSilenceSampleCount: Int,
        lastVoiceOutputSample: Int64,
        acousticDecision: AcousticDecision
    ) -> LineEvidence {
        let length = lineWordRange.count
        // Acceptance gates use this exact inference snapshot. Earlier karaoke
        // coverage is diagnostic only and cannot fill a missing word, prefix,
        // or terminal word in a later completion cycle.
        let currentSnapshotMatches = Set(
            matchedLineWordIndices.filter(lineWordRange.contains)
        )
        let requiredMatches = Self.requiredMatchedWordCount(for: length)
        let requiredPrefix = Self.requiredPrefixWordCount(for: length)
        let requiredCycles = max(
            Self.requiredStableCycleCount(for: length),
            minimumStableCycleCount
        )
        let minimumSpan = minimumRequiredSpeechSpanSampleCount

        var prefixUpperBound = lineWordRange.lowerBound
        while prefixUpperBound < lineWordRange.upperBound,
              currentSnapshotMatches.contains(prefixUpperBound) {
            prefixUpperBound += 1
        }
        let prefixCount = prefixUpperBound - lineWordRange.lowerBound
        let endpointMatched = lineWordRange.last.map(currentSnapshotMatches.contains) ?? false

        let sequenceIsFresh = registerFreshSequence(
            sequence,
            isFreshCycle: isFreshCycle
        )

        let contentAndAcousticQualifyIgnoringSilence = sequenceIsFresh
            && currentSnapshotMatches.count >= requiredMatches
            && prefixCount >= requiredPrefix
            && endpointMatched
            && freshSampleCount >= Self.minimumFreshSampleCount
            && speechSpanSampleCount >= minimumSpan
            && acousticDecision == .identityMatched
        let qualifies = contentAndAcousticQualifyIgnoringSilence
            && silenceRange.contains(trailingSilenceSampleCount)

        if qualifies {
            if stableLastVoiceOutputSample == lastVoiceOutputSample {
                stableCycleCount += 1
            } else {
                // New voice invalidates the prior run. A fully qualifying
                // snapshot after the change is cycle one of a new run.
                stableLastVoiceOutputSample = lastVoiceOutputSample
                stableCycleCount = 1
            }
        } else if sequenceIsFresh {
            // Every newer fresh nonqualifier breaks stability. Duplicate,
            // stale, and explicitly nonfresh callbacks do not mutate it.
            stableLastVoiceOutputSample = nil
            stableCycleCount = 0
        }

        if stableCycleCount >= requiredCycles {
            hasAccepted = true
        }

        let isIdentityMatchedPartial = acousticDecision == .identityMatched
            && progress.matchedLineWordCount > 0

        return LineEvidence(
            progress: progress,
            matchedLineWordIndices: currentSnapshotMatches,
            requiredMatchedWordCount: requiredMatches,
            contiguousPrefixWordCount: prefixCount,
            requiredPrefixWordCount: requiredPrefix,
            stableCycleCount: stableCycleCount,
            requiredStableCycleCount: requiredCycles,
            speechSpanSampleCount: max(0, speechSpanSampleCount),
            minimumSpeechSpanSampleCount: minimumSpan,
            freshSampleCount: max(0, freshSampleCount),
            minimumFreshSampleCount: Self.minimumFreshSampleCount,
            trailingSilenceSampleCount: max(0, trailingSilenceSampleCount),
            minimumTrailingSilenceSampleCount:
                silenceRange.lowerBound,
            maximumTrailingSilenceSampleCount:
                Self.maximumTrailingSilenceSampleCount,
            lastVoiceOutputSample: lastVoiceOutputSample,
            currentCycleQualifies: qualifies,
            contentAndAcousticQualifyIgnoringSilence:
                contentAndAcousticQualifyIgnoringSilence,
            endpointMatched: endpointMatched,
            acousticDecision: acousticDecision,
            isIdentityMatchedPartial: isIdentityMatchedPartial,
            acceptedWordCount: hasAccepted ? currentSnapshotMatches.count : 0,
            isAccepted: hasAccepted
        )
    }

    private mutating func registerFreshSequence(
        _ sequence: UInt64,
        isFreshCycle: Bool
    ) -> Bool {
        let sequenceIsFresh = isFreshCycle
            && (lastFreshSequence.map { sequence > $0 } ?? true)
        if sequenceIsFresh {
            lastFreshSequence = sequence
        }
        return sequenceIsFresh
    }

    static func requiredMatchedWordCount(for lineLength: Int) -> Int {
        let length = max(1, lineLength)
        return length <= 4 ? length : length - 1
    }

    static func requiredPrefixWordCount(for lineLength: Int) -> Int {
        let length = max(1, lineLength)
        // Short lines still require every word. Longer lines already require
        // ordered n-1 coverage plus the endpoint, so a second gap-free prefix
        // veto only punishes one benign decoder omission near the beginning.
        return length <= 4 ? length : 0
    }

    static func requiredStableCycleCount(for lineLength: Int) -> Int {
        // One complete fresh identity-backed observation is one successful
        // ordinary recitation. Standalone Muqatta'at retain their explicit
        // three-cycle floor through `minimumStableCycleCount`.
        return 1
    }

    /// Pace floor for ordinary  lines. The CTC identity comparison,
    /// ordered n-1 word coverage, endpoint, fresh-audio and silence gates still
    /// carry content authority; this bounded floor only rejects implausibly
    /// tiny VAD bursts. It deliberately accommodates a familiar Surah recited
    /// fluidly instead of requiring pedagogical word-by-word pacing.
    static func minimumOrdinarySpeechSpanSampleCount(for lineLength: Int) -> Int {
        let floors = [
            4_800,
            8_000,
            11_200,
            13_600,
            16_000,
            18_400,
            20_800,
            23_200
        ]
        let length = max(1, lineLength)
        guard length > floors.count else { return floors[length - 1] }
        return floors[floors.count - 1] + ((length - floors.count) * 2_400)
    }

    /// Conservative spoken-letter floor retained for standalone Muqatta'at.
    /// Their one catalog word can contain several deliberately elongated
    /// letters, so the ordinary word-count pacing table does not apply.
    static func minimumSpeechSpanSampleCount(for lineLength: Int) -> Int {
        let existingFloors = [
            6_400,
            16_800,
            23_200,
            28_800,
            33_600,
            37_600,
            40_000,
            42_400
        ]
        let length = max(1, lineLength)
        guard length > existingFloors.count else {
            return existingFloors[length - 1]
        }

        // The canonical  wrap normally caps at eight words. Preserve a
        // conservative monotonic 170 ms floor if a future planner produces more.
        return existingFloors[existingFloors.count - 1]
            + ((length - existingFloors.count) * 2_720)
    }
}
