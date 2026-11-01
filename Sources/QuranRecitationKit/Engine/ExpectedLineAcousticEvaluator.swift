import Foundation

/// Everything a target-vs-confuser scorer needs for one fresh model window.
/// The decoded transcript is scoped to this call and is never published,
/// persisted, uploaded, or logged by the  service.
struct AcousticEvaluationRequest: Sendable {
    let inferenceOutput: OnnxInferenceOutput
    let decodedResult: CTCDecodeResult
    let recognitionRequest: RecognitionRequest
    let expectedNormalizedAyahWords: [String]
    let expectedNormalizedLineWords: [String]
    let expectedLineTokenIDs: [Int]?
    let matchedAyahWordIndices: Set<Int>
    let freshAudioDuration: TimeInterval
    let speechSpan: TimeInterval
    /// The line that precedes the requested one in the reciter's order, when
    /// known. Its last word fences the frame-progress prefix: this line may
    /// not begin before that word has ended in the greedy token stream.
    var precedingLineRequest: RecognitionRequest? = nil
    /// The window's audio length in seconds (for frame ↔ time in the fence).
    var windowDuration: TimeInterval = 0
    /// CHAINED PROGRESS: for a line that FOLLOWS the verified line in the
    /// same window, the CTC frame after which its prefix may begin — the
    /// frame of the previous line's last matched token. Exact, not timed.
    var minimumProgressStartFrame: Int? = nil
}

protocol AcousticEvidenceEvaluating: Sendable {
    func evaluate(
        _ request: AcousticEvaluationRequest
    ) throws -> AcousticDecision
}

/// Explicitly uncalibrated identity gate authorized for ordinary  line
/// completion. Standalone Muqatta'at use their exact current-window canonical
/// token suffix instead, avoiding CTC length bias between shared-prefix forms.
/// This value is not a false-accept-rate claim.
enum OrdinaryLineIdentityHeuristic {
    static let name = "uncalibrated-target-vs-distinct-quran-confuser-v1"
    static let minimumMarginPerFrame = 0.035
}

struct AcousticEvaluation: Equatable, Sendable {
    let decision: AcousticDecision
    /// Ordinary target-vs-strongest-confuser CTC margin. Standalone
    /// Muqatta'at and inconclusive resource paths intentionally return nil.
    let targetMarginPerFrame: Double?
    /// Display-only exact greedy-token progress. This never participates in
    /// line acceptance and is nil if the pinned catalog cannot be validated.
    let tokenFrameProgress: ExpectedTokenFrameProgress?
    init(
        decision: AcousticDecision,
        targetMarginPerFrame: Double?,
        tokenFrameProgress: ExpectedTokenFrameProgress? = nil
    ) {
        self.decision = decision
        self.targetMarginPerFrame = targetMarginPerFrame
        self.tokenFrameProgress = tokenFrameProgress
    }
}

/// Exact, display-only progress through one canonical line token sequence.
/// Counts are line-local; the service maps them back to ayah-relative words.
final class ExpectedLineAcousticEvaluator:
    AcousticEvidenceEvaluating,
    @unchecked Sendable
{
    private let catalog: QuranTokenCatalog
    private let scorer: CTCScorer

    init(
        catalog: QuranTokenCatalog,
        scorer: CTCScorer = CTCScorer(blankID: 1_024)
    ) {
        self.catalog = catalog
        self.scorer = scorer
    }

    func evaluate(
        _ request: AcousticEvaluationRequest
    ) throws -> AcousticDecision {
        try evaluateWithDiagnostics(request).decision
    }

    /// The token spelling of the last word of the line that precedes the
    /// requested one (empty when unknown or not in the catalog). Used only to
    /// fence the display-only frame progress; never as evidence.
    private func precedingLineLastWordTokenIDs(
        _ request: AcousticEvaluationRequest
    ) -> (canonical: [Int], alternate: [Int]) {
        guard let preceding = request.precedingLineRequest,
              let line = try? catalog.line(
                  surahNumber: preceding.surahNumber,
                  ayahNumber: preceding.ayahNumber,
                  ayahWordRange: preceding.ayahWordRange
              ) else {
            return ([], [])
        }
        func lastWord(tokenIDs: [Int], wordTokenEnds: [Int]) -> [Int] {
            guard let end = wordTokenEnds.last, end == tokenIDs.count else {
                return []
            }
            let start = wordTokenEnds.count >= 2
                ? wordTokenEnds[wordTokenEnds.count - 2]
                : 0
            guard start < end else { return [] }
            return Array(tokenIDs[start..<end])
        }
        let canonical = lastWord(
            tokenIDs: line.tokenIDs,
            wordTokenEnds: line.wordTokenEnds
        )
        let alternate = QuranPronunciationTokenVariants
            .auditedAlternateTokenization(
                expectedTokenIDs: line.tokenIDs,
                wordTokenEnds: line.wordTokenEnds,
                surahNumber: preceding.surahNumber,
                ayahNumber: preceding.ayahNumber,
                ayahWordRange: preceding.ayahWordRange
            )
            .map { lastWord(tokenIDs: $0.tokenIDs, wordTokenEnds: $0.wordTokenEnds) }
            ?? []
        return (canonical, alternate == canonical ? [] : alternate)
    }

    func evaluateWithDiagnostics(
        _ request: AcousticEvaluationRequest
    ) throws -> AcousticEvaluation {
        let recognition = request.recognitionRequest
        let configuredMuqattaatAuthority = try
            MuqattaatEndpointAuthorityResolver.resolveAutomaticTarget(
                surahNumber: recognition.surahNumber,
                ayahNumber: recognition.ayahNumber,
                ayahWordRange: recognition.ayahWordRange,
                normalizedWords: request.expectedNormalizedLineWords
            )
        let catalogAyahWords = try catalog.normalizedAyahWords(
            surahNumber: recognition.surahNumber,
            ayahNumber: recognition.ayahNumber
        )
        if let authority = configuredMuqattaatAuthority,
           catalogAyahWords != request.expectedNormalizedAyahWords {
            throw Self.catalogMismatch(
                authority: authority,
                actualWords: catalogAyahWords,
                actualTokenIDs: []
            )
        }
        guard catalogAyahWords == request.expectedNormalizedAyahWords else {
            // A planner/corpus mismatch must never be papered over by scoring
            // token IDs that describe different visible Quran text.
            return AcousticEvaluation(
                decision: .inconclusive,
                targetMarginPerFrame: nil
            )
        }

        let catalogTarget = try catalog.line(
            surahNumber: recognition.surahNumber,
            ayahNumber: recognition.ayahNumber,
            ayahWordRange: recognition.ayahWordRange
        )
        if let authority = configuredMuqattaatAuthority,
           catalogTarget.normalizedWords != authority.expectedNormalizedWords
            || catalogTarget.tokenIDs != authority.expectedCanonicalTokenIDs {
            throw Self.catalogMismatch(
                authority: authority,
                actualWords: catalogTarget.normalizedWords,
                actualTokenIDs: catalogTarget.tokenIDs
            )
        }
        guard catalogTarget.normalizedWords == request.expectedNormalizedLineWords else {
            return AcousticEvaluation(
                decision: .inconclusive,
                targetMarginPerFrame: nil
            )
        }
        if let suppliedTokenIDs = request.expectedLineTokenIDs,
           suppliedTokenIDs != catalogTarget.tokenIDs {
            if let authority = configuredMuqattaatAuthority {
                throw Self.catalogMismatch(
                    authority: authority,
                    actualWords: catalogTarget.normalizedWords,
                    actualTokenIDs: suppliedTokenIDs
                )
            }
            return AcousticEvaluation(
                decision: .inconclusive,
                targetMarginPerFrame: nil
            )
        }
        let targetTokenIDs = catalogTarget.tokenIDs
        guard !targetTokenIDs.isEmpty else {
            return AcousticEvaluation(
                decision: .inconclusive,
                targetMarginPerFrame: nil
            )
        }
        let pronunciationVariant = QuranPronunciationTokenVariants
            .auditedAlternateTokenization(
                expectedTokenIDs: targetTokenIDs,
                wordTokenEnds: catalogTarget.wordTokenEnds,
                surahNumber: recognition.surahNumber,
                ayahNumber: recognition.ayahNumber,
                ayahWordRange: recognition.ayahWordRange
            )
        let precedingSpellings = precedingLineLastWordTokenIDs(request)
        // The previous line's tail can only sit in the window's first
        // ~0.6 s (the lead-in plus one late token); fence nothing later.
        let frameCount = request.decodedResult.frameTokenIDs.count
        let fenceFrameLimit: Int? = request.windowDuration > 0
            ? Int((Double(frameCount) * min(1, 0.6 / request.windowDuration)).rounded(.up))
            : nil
        let canonicalTokenFrameProgress = ExpectedTokenFrameProgressAnalyzer.analyze(
            frameTokenIDs: request.decodedResult.frameTokenIDs,
            blankID: scorer.blankID,
            expectedTokenIDs: targetTokenIDs,
            wordTokenEnds: catalogTarget.wordTokenEnds,
            precedingTokenIDs: precedingSpellings.canonical,
            precedingAlternateTokenIDs: precedingSpellings.alternate,
            precedingFenceFrameLimit: fenceFrameLimit,
            minimumStartFrame: request.minimumProgressStartFrame
        )
        let tokenFrameProgress = QuranPronunciationTokenVariants
            .bestFrameProgress(
                canonical: canonicalTokenFrameProgress,
                frameTokenIDs: request.decodedResult.frameTokenIDs,
                blankID: scorer.blankID,
                expectedTokenIDs: targetTokenIDs,
                wordTokenEnds: catalogTarget.wordTokenEnds,
                surahNumber: recognition.surahNumber,
                ayahNumber: recognition.ayahNumber,
                ayahWordRange: recognition.ayahWordRange,
                precedingTokenIDs: precedingSpellings.canonical,
                precedingAlternateTokenIDs: precedingSpellings.alternate,
                precedingFenceFrameLimit: fenceFrameLimit,
                minimumStartFrame: request.minimumProgressStartFrame
            )

        // Validate the frozen standalone Muqatta'at identity before choosing
        // its exact canonical-suffix path. A resolver mismatch is a resource
        // configuration error, never a different completion mode.
        let catalogMuqattaatAuthority = try
            MuqattaatEndpointAuthorityResolver.resolve(
            surahNumber: catalogTarget.surahNumber,
            ayahNumber: catalogTarget.ayahNumber,
            ayahWordRange: catalogTarget.ayahWordRange,
            normalizedWords: catalogTarget.normalizedWords,
            canonicalTokenIDs: targetTokenIDs
        )
        if catalogMuqattaatAuthority != configuredMuqattaatAuthority,
           let authority = configuredMuqattaatAuthority
                ?? catalogMuqattaatAuthority {
            throw Self.catalogMismatch(
                authority: authority,
                actualWords: catalogTarget.normalizedWords,
                actualTokenIDs: targetTokenIDs
            )
        }

        // The canonical form may appear as the final collapsed tokens even
        // when SentencePiece text expansion does not produce the one rendered
        // semantic word. This exact suffix is sufficient current-window
        // identity evidence; a proper prefix or wrong suffix is not.
        if let authority = configuredMuqattaatAuthority {
            return AcousticEvaluation(
                decision: MuqattaatAutomaticIdentity.decision(
                    decodedTokenIDs: request.decodedResult.tokenIDs,
                    authority: authority
                ),
                targetMarginPerFrame: nil,
                tokenFrameProgress: tokenFrameProgress
            )
        }

        var targetTokenSequences = [targetTokenIDs]
        if let pronunciationVariant,
           pronunciationVariant.tokenIDs != targetTokenIDs {
            targetTokenSequences.append(pronunciationVariant.tokenIDs)
        }

        let confusers = try catalog.nearbyConfusers(
            surahNumber: recognition.surahNumber,
            ayahNumber: recognition.ayahNumber,
            ayahWordRange: recognition.ayahWordRange
        )
        guard !confusers.isEmpty else {
            return AcousticEvaluation(
                decision: .inconclusive,
                targetMarginPerFrame: nil,
                tokenFrameProgress: tokenFrameProgress
            )
        }

        let currentLineMatches = request.matchedAyahWordIndices.filter {
            recognition.ayahWordRange.contains($0)
        }
        let currentLineEndpointMatched = recognition.ayahWordRange.last.map {
            currentLineMatches.contains($0)
        } ?? false
        let currentLineTextGateSatisfied = currentLineMatches.count
            >= LineAcceptancePolicy.requiredMatchedWordCount(
                for: recognition.ayahWordRange.count
            )
            && currentLineEndpointMatched
        let immediateContinuation = try catalog.immediateFollowingLine(
            surahNumber: recognition.surahNumber,
            ayahNumber: recognition.ayahNumber,
            ayahWordRange: recognition.ayahWordRange
        )

        // A visual  line break is not a Quranic pause. Once the
        // unchanged current-line word gate is already satisfied, correct
        // speech from the exact next canonical line may remain in the same
        // rolling microphone window. Score current+continuation as an allowed
        // path while retaining the bare continuation as a negative comparator.
        // Full fluent speech therefore beats next-only speech acoustically;
        // the unchanged word gate remains a second independent skip fence.
        targetTokenSequences = Self.ordinaryTargetTokenSequences(
            currentTargetTokenSequences: targetTokenSequences,
            immediateContinuationTokenIDs: immediateContinuation?.tokenIDs,
            currentLineTextGateSatisfied: currentLineTextGateSatisfied
        )
        guard let strongestTarget = try Self.strongestReachableTargetScore(
            targetTokenSequences,
            logProbabilities: request.inferenceOutput.logProbabilities,
            timeSteps: request.inferenceOutput.timeSteps,
            vocabularySize: request.inferenceOutput.vocabularySize,
            scorer: scorer
        ) else {
            return AcousticEvaluation(
                decision: .inconclusive,
                targetMarginPerFrame: nil,
                tokenFrameProgress: tokenFrameProgress
            )
        }

        var strongestConfuser = -Double.infinity
        var seenConfuserTokenSequences = Set(targetTokenSequences)
        for confuser in confusers
        where seenConfuserTokenSequences.insert(confuser.tokenIDs).inserted {
            // Repeated Quran phrases can legitimately have the exact same
            // acoustic token sequence at several canonical locations. They
            // are equivalent expected utterances, not distinguishable wrong
            // text; treating one as a negative would force a zero margin and
            // make the valid repeated line impossible to complete.
            guard let score = try Self.scoreReachableConfuser(
                confuser.tokenIDs,
                logProbabilities: request.inferenceOutput.logProbabilities,
                timeSteps: request.inferenceOutput.timeSteps,
                vocabularySize: request.inferenceOutput.vocabularySize,
                scorer: scorer
            ) else { continue }
            strongestConfuser = max(
                strongestConfuser,
                score
            )
        }
        guard strongestConfuser.isFinite else {
            return AcousticEvaluation(
                decision: .inconclusive,
                targetMarginPerFrame: nil,
                tokenFrameProgress: tokenFrameProgress
            )
        }

        let targetMargin = strongestTarget - strongestConfuser
        let decision: AcousticDecision = targetMargin
            >= OrdinaryLineIdentityHeuristic.minimumMarginPerFrame
            ? .identityMatched
            : .rejected
        return AcousticEvaluation(
            decision: decision,
            targetMarginPerFrame: targetMargin,
            tokenFrameProgress: tokenFrameProgress
        )
    }

    /// Extends only already-authorized current-line targets with the exact
    /// canonical successor. The bare successor is deliberately not returned
    /// here: it remains in the confuser set so future-only speech still loses.
    static func ordinaryTargetTokenSequences(
        currentTargetTokenSequences: [[Int]],
        immediateContinuationTokenIDs: [Int]?,
        currentLineTextGateSatisfied: Bool
    ) -> [[Int]] {
        var targets = currentTargetTokenSequences
        guard currentLineTextGateSatisfied,
              let continuation = immediateContinuationTokenIDs,
              !continuation.isEmpty else { return targets }
        targets.append(contentsOf: currentTargetTokenSequences.map {
            $0 + continuation
        })
        return targets
    }

    /// Scores each tightly scoped expected spelling and keeps the strongest
    /// reachable CTC path. A longer pronunciation variant may be unreachable
    /// in an early window; that variant is skipped without invalidating the
    /// canonical target. Duplicate sequences never receive extra weight.
    static func strongestReachableTargetScore(
        _ tokenSequences: [[Int]],
        logProbabilities: [Float],
        timeSteps: Int,
        vocabularySize: Int,
        scorer: CTCScorer
    ) throws -> Double? {
        var strongest = -Double.infinity
        var seen: Set<[Int]> = []
        for tokenSequence in tokenSequences
        where seen.insert(tokenSequence).inserted {
            guard let score = try scoreReachableConfuser(
                tokenSequence,
                logProbabilities: logProbabilities,
                timeSteps: timeSteps,
                vocabularySize: vocabularySize,
                scorer: scorer
            ) else { continue }
            strongest = max(strongest, score)
        }
        return strongest.isFinite ? strongest : nil
    }

    private static func catalogMismatch(
        authority: MuqattaatEndpointAuthority,
        actualWords: [String],
        actualTokenIDs: [Int]
    ) -> MuqattaatEndpointAuthorityError {
        .catalogMismatch(
            location: authority.location,
            expectedWords: authority.expectedNormalizedWords,
            actualWords: actualWords,
            expectedTokenIDs: authority.expectedCanonicalTokenIDs,
            actualTokenIDs: actualTokenIDs
        )
    }

    /// The exact lower bound for a sequence in the standard CTC topology.
    ///
    /// Adjacent equal labels cannot be emitted on consecutive frames because
    /// collapsing would merge them, so each such pair requires one additional
    /// intervening blank frame. `nil` means the integer computation overflowed
    /// and must fail closed rather than being classified as unreachable.
    static func minimumRequiredCTCTimeSteps(for tokenIDs: [Int]) -> Int? {
        var adjacentRepeatCount = 0
        for (previous, current) in zip(tokenIDs, tokenIDs.dropFirst())
        where previous == current {
            let (nextCount, overflowed) = adjacentRepeatCount
                .addingReportingOverflow(1)
            guard !overflowed else { return nil }
            adjacentRepeatCount = nextCount
        }

        let (minimumTimeSteps, overflowed) = tokenIDs.count
            .addingReportingOverflow(adjacentRepeatCount)
        return overflowed ? nil : minimumTimeSteps
    }

    /// Scores one structurally valid confuser, returning nil only when standard
    /// CTC cannot place that sequence in the available frame count. Every other
    /// validation or numeric error propagates so the caller remains fail-closed.
    static func scoreReachableConfuser(
        _ tokenIDs: [Int],
        logProbabilities: [Float],
        timeSteps: Int,
        vocabularySize: Int,
        scorer: CTCScorer
    ) throws -> Double? {
        try validateConfuserTokenSequence(
            tokenIDs,
            vocabularySize: vocabularySize,
            blankID: scorer.blankID
        )

        // A CTC path needs one frame per token plus an intervening blank for
        // each adjacent repeated token. Validation deliberately happens first
        // so malformed data cannot hide behind an insufficient frame count.
        guard let minimumTimeSteps = minimumRequiredCTCTimeSteps(for: tokenIDs) else {
            throw CTCScorerError.alignmentWorkspaceOverflow(
                timeSteps: timeSteps,
                stateCount: Int.max
            )
        }
        guard timeSteps >= minimumTimeSteps else { return nil }

        return try scorer.score(
            logProbabilities: logProbabilities,
            timeSteps: timeSteps,
            vocabularySize: vocabularySize,
            tokenIDs: tokenIDs
        ).logProbabilityPerFrame
    }

    /// Mirrors the scorer's token-domain validation for confusers before the
    /// reachability skip. This prevents an invalid token or blank label from
    /// being silently ignored merely because the sequence is also too long
    /// for the current window.
    static func validateConfuserTokenSequence(
        _ tokenIDs: [Int],
        vocabularySize: Int,
        blankID: Int
    ) throws {
        guard !tokenIDs.isEmpty else {
            throw CTCScorerError.emptyTokenSequence
        }
        if let invalid = tokenIDs.first(
            where: { !(0..<vocabularySize).contains($0) }
        ) {
            throw CTCScorerError.tokenOutsideVocabulary(invalid)
        }
        guard !tokenIDs.contains(blankID) else {
            throw CTCScorerError.blankInsideTokenSequence
        }
    }
}
