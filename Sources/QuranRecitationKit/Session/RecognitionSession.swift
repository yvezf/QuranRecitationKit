import CryptoKit
import Foundation

protocol AcousticModelRunning: Sendable {
    func run(monoPCM16kHz audio: [Float]) async throws -> OnnxInferenceOutput
    func cancelPendingInference()
}
extension OnnxRunner: AcousticModelRunning {}

/// The service's newest-window / terminal mailbox, generation fences and sample-domain
/// gates, with PCM ingestion replacing its former device-capture and product adapters.
actor RecognitionSession {
    private struct Segment: Sendable {
        let request: RecognitionRequest
        let words: [String]
        let tokens: QuranTokenLine
        let closesTargetAyah: Bool
    }
    private struct Snapshot: Sendable {
        let generation: UInt64
        let audio: [Float]
        let end: Int64
        let voiceEnd: Int64
        let speechSpan: Int
        let fresh: Int
        let trailing: Int
        let terminal: Bool
        let final: Bool
    }
    private let runner: any AcousticModelRunning
    private let configuration: RecitationConfiguration
    private let displayCatalog: QuranCatalog
    private let catalog: QuranTokenCatalog
    private let decoder: GreedyCTCDecoder
    private let evaluator: ExpectedLineAcousticEvaluator
    private let continuation: AsyncStream<RecitationEvent>.Continuation
    private var segments: [Segment] = []
    private var position = 0
    private var policy: LineAcceptancePolicy?
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var total: Int64 = 0
    private var voiceEnd: Int64 = 0
    private var voiceStart: Int64?
    private var audio = PCMWindow(capacity: 192000)
    private var fresh = 0
    private var mailbox = NewestSnapshotMailbox<Snapshot>()
    private var worker: Task<Void, Never>?
    private var verses: [VerseMatch] = []
    private var transcript = ""
    private var acceptedText: [String] = []
    private var matched: [Int: Set<Int>] = [:]
    private var lastProgress: WordProgress?
    private var lastError: Error?
    private var stopped = true
    private var stopping = false
    private var lastVerseSample: Int64 = 0
    private var state: RecognitionState = .idle

    init(runner: any AcousticModelRunning, configuration: RecitationConfiguration,
         continuation: AsyncStream<RecitationEvent>.Continuation) throws {
        self.runner = runner; self.configuration = configuration; self.continuation = continuation
        displayCatalog = try QuranCatalog()
        catalog = try QuranTokenCatalog.bundled()
        evaluator = ExpectedLineAcousticEvaluator(catalog: catalog)
        let url = Bundle.module.url(forResource: "vocab", withExtension: "json")!
        let data = try Data(contentsOf: url)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
            == "c55877f3bff8bc3aaefc160e8c2fb88cb349088d092513d40210ccfe535e671b" else {
            throw ModelPackError.incompatibleManifest
        }
        let vocab = try JSONDecoder().decode([String: String].self, from: data)
        decoder = try GreedyCTCDecoder(vocabulary: Dictionary(uniqueKeysWithValues: vocab.compactMap {
            guard let id = Int($0.key) else { return nil }; return (id, $0.value)
        }), blankID: 1024)
        continuation.yield(.state(.idle))
    }
    deinit { worker?.cancel(); continuation.finish() }

    func setExpected(_ target: RecitationTarget) throws {
        // Validate before discarding the current target, so a malformed caller request is harmless.
        let chosen: [(Int, Int, Range<Int>)]
        let q = displayCatalog
        switch target {
        case .surah(let surah):
            let ayahs = q.ayahs(in: surah)
            guard !ayahs.isEmpty else { throw QuranTokenCatalogError.missingAyah(surah: surah, ayah: 1) }
            chosen = try ayahs.map { a in (surah, a.number, 0..<(try catalog.normalizedAyahWords(surahNumber: surah, ayahNumber: a.number)).count) }
        case .ayahs(let surah, let range):
            guard range.lowerBound > 0, range.upperBound <= q.ayahs(in: surah).count else {
                throw QuranTokenCatalogError.missingAyah(surah: surah, ayah: range.upperBound)
            }
            chosen = try range.map { (surah, $0, 0..<(try catalog.normalizedAyahWords(surahNumber: surah, ayahNumber: $0)).count) }
        case .words(let surah, let ayah, let range): chosen = [(surah, ayah, range)]
        }
        var newSegments: [Segment] = []
        let sessionID = UUID()
        let surah = chosen[0].0
        var sources: [SurahCanonicalWordSource] = []
        var ayahOffsets: [Int:Int] = [:]
        for (segment, ayah) in q.ayahs(in: surah).enumerated() {
            ayahOffsets[ayah.number] = sources.count
            let words = try catalog.normalizedAyahWords(surahNumber: surah, ayahNumber: ayah.number)
            sources += words.enumerated().map { SurahCanonicalWordSource(normalizedText: $0.element, ayahNumber: ayah.number, ayahWordIndex: $0.offset, segmentIndex: segment) }
        }
        let index = try CanonicalWordIndex(surahNumber: surah, wordSources: sources)
        let limits = SurahExpectedWindowLimits(backtrackWordCount: configuration.backtrackWords,
            maximumLookaheadWordCount: configuration.lookaheadWords, maximumForwardSegmentCount: 4)
        for (surah, ayah, range) in chosen {
            let words = try catalog.normalizedAyahWords(surahNumber: surah, ayahNumber: ayah)
            _ = try catalog.line(surahNumber: surah, ayahNumber: ayah, ayahWordRange: range)
            // Bounded acoustic windows, independent of any typesetting plan. Public completion is ayah-scoped.
            var start = range.lowerBound
            let width = min(8, max(1, configuration.lookaheadWords))
            while start < range.upperBound {
                let offset = ayahOffsets[ayah] ?? 0
                let window = try index.expectedWindow(aroundVerifiedCursor: offset + start, limits: limits)
                let end = min(start + width, range.upperBound, window.globalWordRange.upperBound - offset)
                let request = try RecognitionRequest(sessionID: sessionID, surahNumber: surah,
                    ayahNumber: ayah, ayahWordRange: start..<end, expectedAyahWordCount: words.count)
                newSegments.append(Segment(request: request, words: words,
                    tokens: try catalog.line(surahNumber: surah, ayahNumber: ayah, ayahWordRange: start..<end),
                    closesTargetAyah: end == range.upperBound))
                start = end
            }
        }
        clear()
        segments = newSegments; stopped = false
        configurePolicy(); emitState(.listening)
    }
    func reset() {
        clear(); segments = []; emitState(.idle)
    }
    private func clear() {
        generation &+= 1; runner.cancelPendingInference(); worker?.cancel(); worker = nil
        mailbox.removeAll(); position = 0; policy = nil
        total = 0; voiceEnd = 0; voiceStart = nil; audio = PCMWindow(capacity: Int(configuration.maximumWindowSeconds * 16000)); fresh = 0
        verses = []; transcript = ""; acceptedText = []; matched = [:]; lastProgress = nil
        lastError = nil; stopped = true; stopping = false; lastVerseSample = 0
    }
    private func configurePolicy() {
        guard position < segments.count else { policy = nil; return }
        let s = segments[position]
        let authority = try? MuqattaatEndpointAuthorityResolver.resolveAutomaticTarget(
            surahNumber: s.request.surahNumber, ayahNumber: s.request.ayahNumber,
            ayahWordRange: s.request.ayahWordRange, normalizedWords: s.tokens.normalizedWords)
        policy = LineAcceptancePolicy(lineWordRange: s.request.ayahWordRange, standaloneMuqattaatForm: authority?.form,
            minimumTrailingSilenceSamples: configuration.policy == .lenient ? 3200 : 6400,
            requiredStableCycles: configuration.policy == .conservative ? 2 : 1)
    }
    func feed(_ pcm: [Float]) {
        guard !stopped, !stopping, position < segments.count else { return }
        guard pcm.allSatisfy(\.isFinite) else { lastError = OnnxRunnerError.invalidAudio("Non-finite PCM"); return }
        // Ingest in fixed 10 ms VAD blocks; caller chunk size never changes endpoint timing.
        for start in stride(from: 0, to: pcm.count, by: 160) {
            let chunk = pcm[start..<min(start + 160, pcm.count)]
            total += Int64(chunk.count); fresh += chunk.count
            let rms = sqrt(chunk.reduce(Float(0)) { $0 + $1 * $1 } / Float(chunk.count))
            if rms > 0.004 {
                if voiceStart == nil { voiceStart = total - Int64(chunk.count) }
                voiceEnd = total
            }
            audio.append(contentsOf: chunk)
            let silence = Int(total - voiceEnd)
            if fresh >= LineAcceptancePolicy.minimumFreshSampleCount,
               voiceStart != nil, configuration.liveTracking || silence >= 6400 {
                offer(terminal: silence > 32000)
            }
        }
    }
    private func offer(terminal: Bool, padded: Bool = false) {
        guard audio.count > 0 else { return }
        let trailing = Int(total - voiceEnd)
        var samples = audio.samples
        if padded && trailing < 12800 {
            samples.append(contentsOf: repeatElement(0, count: 12800 - trailing))
            let cap = Int(configuration.maximumWindowSeconds * 16000)
            if samples.count > cap { samples.removeFirst(samples.count - cap) }
        }
        let snapshot = Snapshot(generation: generation, audio: samples, end: total,
            voiceEnd: voiceEnd, speechSpan: Int(voiceEnd - (voiceStart ?? voiceEnd)),
            fresh: max(fresh, padded ? 3200 : 0), trailing: padded ? max(12800, min(32000, trailing)) : trailing,
            terminal: terminal, final: padded)
        mailbox.offer(snapshot, isTerminal: terminal); fresh = 0
        if worker == nil {
            let epoch = generation
            worker = Task { await self.drain(epoch: epoch) }
        }
    }
    private func drain(epoch: UInt64) async {
        while !Task.isCancelled, epoch == generation, let snapshot = mailbox.takeNext() {
            guard position < segments.count else { break }
            do {
                let output = try await runner.run(monoPCM16kHz: snapshot.audio)
                guard epoch == generation, !Task.isCancelled else { return }
                try analyze(output, snapshot: snapshot)
            } catch {
                guard epoch == generation, !Task.isCancelled else { return }
                lastError = error; continuation.yield(.needsRetry(.inconclusive))
            }
        }
        if epoch == generation { worker = nil }
    }
    private func analyze(_ output: OnnxInferenceOutput, snapshot: Snapshot) throws {
        let decoded = try decoder.decode(logProbabilities: output.logProbabilities,
            timeSteps: output.timeSteps, vocabularySize: output.vocabularySize)
        if decoded.text != transcript {
            transcript = decoded.text
            continuation.yield(.rawTranscript(RawTranscript(text: transcript, confidence: 0)))
        }
        var minimumFrame: Int? = nil
        // At most four acoustic targets per pass. A terminal drain repeats bounded work for longer supplied clips.
        for _ in 0..<4 {
            guard position < segments.count else { break }
            let s = segments[position]; let r = s.request
            let scoped = scope(output: output, decoded: decoded, segment: s, after: minimumFrame)
            let scopedDecoded = try decoder.decode(logProbabilities: scoped.output.logProbabilities, timeSteps: scoped.output.timeSteps, vocabularySize: scoped.output.vocabularySize)
            let scopedAlignment = ExpectedWordAligner.align(decodedText: scopedDecoded.text, expectedAyahWords: s.words, lineWordRange: r.ayahWordRange)
            let evaluation = try evaluator.evaluateWithDiagnostics(AcousticEvaluationRequest(
                inferenceOutput: scoped.output, decodedResult: scopedDecoded, recognitionRequest: r,
                expectedNormalizedAyahWords: s.words, expectedNormalizedLineWords: s.tokens.normalizedWords,
                expectedLineTokenIDs: s.tokens.tokenIDs, matchedAyahWordIndices: scopedAlignment.matchedAyahWordIndices,
                freshAudioDuration: Double(snapshot.fresh) / 16000, speechSpan: Double(snapshot.speechSpan) / 16000,
                windowDuration: Double(snapshot.audio.count) / 16000))
            var indices = scopedAlignment.matchedAyahWordIndices
            // Exact alternate spellings can supply a word the fuzzy text projection cannot represent.
            if let fp = evaluation.tokenFrameProgress {
                indices.formUnion(r.ayahWordRange.prefix(fp.completedWordCount))
            }
            var end = r.ayahWordRange.lowerBound
            while indices.contains(end) && end < r.ayahWordRange.upperBound { end += 1 }
            let confidence = min(1, max(0, evaluation.targetMarginPerFrame ?? 0))
            if !indices.isEmpty {
                matched[r.ayahNumber, default: []].formUnion(indices)
                let p = WordProgress(surah: r.surahNumber, ayah: r.ayahNumber,
                    wordIndex: indices.max() ?? r.ayahWordRange.lowerBound, totalWords: s.words.count,
                    matchedWordIndices: matched[r.ayahNumber] ?? [], confidence: confidence)
                if p != lastProgress { lastProgress = p; continuation.yield(.wordProgress(p)) }
            }
            let progress = InternalLineProgress(sessionID: r.sessionID, sequence: sequence,
                surahNumber: r.surahNumber, ayahNumber: r.ayahNumber,
                focusWordIndex: max(r.ayahWordRange.lowerBound, end - 1), lineWordRange: r.ayahWordRange,
                cumulativeMatchedWordIndices: indices, contiguousMatchedWordRange: r.ayahWordRange.lowerBound..<end)
            var evidence: LineEvidence?
            let firstTick = snapshot.final ? 6400 : min(32000, snapshot.trailing)
            let ticks = [firstTick] + TerminalStabilityTickPlanner.additionalTrailingSilenceTicks(
                after: firstTick, through: snapshot.trailing)
            for tick in ticks {
                sequence &+= 1
                evidence = policy?.evaluate(progress: progress, matchedLineWordIndices: indices,
                    sequence: sequence, isFreshCycle: true, freshSampleCount: snapshot.fresh,
                    speechSpanSampleCount: snapshot.speechSpan, trailingSilenceSampleCount: tick,
                    lastVoiceOutputSample: snapshot.voiceEnd, acousticDecision: evaluation.decision)
            }
            // Additional presets never bypass identity; conservative also requires every word.
            let presetAccepts = configuration.policy != .conservative || indices.isSuperset(of: Set(r.ayahWordRange))
            // A long ayah has bounded internal acoustic spans, not displayed lines.
            // Fully emitted, identity-backed nonterminal spans may move the internal
            // cursor while speaking. The public verse event still requires the final
            // span's endpoint gate, and all preceding spans must have passed in order.
            let supportedInternalSpan = !s.closesTargetAyah
                && evaluation.decision == .identityMatched
                && evaluation.tokenFrameProgress?.isCompleteLine == true
                && indices.isSuperset(of: Set(r.ayahWordRange))
                && snapshot.speechSpan >= LineAcceptancePolicy.minimumOrdinarySpeechSpanSampleCount(for: r.ayahWordRange.count)
            guard (evidence?.isAccepted == true || supportedInternalSpan), presetAccepts else {
                if snapshot.terminal || snapshot.final {
                    continuation.yield(.needsRetry(snapshot.speechSpan < 4800 ? .tooShort :
                        decoded.text.isEmpty ? .noise : evaluation.decision == .rejected ? .offTarget : .inconclusive))
                }
                break
            }
            acceptedText.append(s.tokens.normalizedWords.joined(separator: " "))
            if s.closesTargetAyah {
                let match = VerseMatch(surah: r.surahNumber, ayah: r.ayahNumber, confidence: confidence,
                    durationSeconds: Double(snapshot.voiceEnd - lastVerseSample) / 16000)
                verses.append(match); continuation.yield(.verseMatch(match)); lastVerseSample = snapshot.voiceEnd
            }
            minimumFrame = evaluation.tokenFrameProgress?.matchedEndFrame.map { $0 + scoped.offset + 1 }
            if let frameEnd = minimumFrame, !snapshot.final {
                // Keep bounded previously verified context for the next model window.
                let lastWords = min(configuration.backtrackWords, s.tokens.wordTokenEnds.count)
                let precedingTokens = lastWords == 0 ? 0 : s.tokens.tokenIDs.count - (lastWords == s.tokens.wordTokenEnds.count ? 0 : s.tokens.wordTokenEnds[s.tokens.wordTokenEnds.count-lastWords-1])
                let frameToKeep = max(0, frameEnd - precedingTokens * 2)
                let snapshotStart = snapshot.end - Int64(snapshot.audio.count)
                let keepFrom = snapshotStart + Int64(Double(frameToKeep) / Double(max(1,output.timeSteps)) * Double(snapshot.audio.count))
                let ringStart = total - Int64(audio.count)
                audio.discardFirst(Int(max(0,keepFrom-ringStart)))
            }
            position += 1; configurePolicy()
        }
    }
    /// Limit CTC comparison to a span located by actual greedy emissions, never by
    /// forcing the expected text onto unrelated frames. This prevents later ayahs
    /// in one fluent window from acting as negative evidence for its first ayah.
    private func scope(output: OnnxInferenceOutput, decoded: CTCDecodeResult, segment: Segment,
                       after minimum: Int?) -> (output: OnnxInferenceOutput, offset: Int) {
        var start = min(max(0, minimum ?? 0), max(0, output.timeSteps - 1))
        let canonical = ExpectedTokenFrameProgressAnalyzer.analyze(frameTokenIDs: decoded.frameTokenIDs,
            blankID: 1024, expectedTokenIDs: segment.tokens.tokenIDs, wordTokenEnds: segment.tokens.wordTokenEnds,
            minimumStartFrame: start)
        let progress = QuranPronunciationTokenVariants.bestFrameProgress(canonical: canonical,
            frameTokenIDs: decoded.frameTokenIDs, blankID: 1024, expectedTokenIDs: segment.tokens.tokenIDs,
            wordTokenEnds: segment.tokens.wordTokenEnds, surahNumber: segment.request.surahNumber,
            ayahNumber: segment.request.ayahNumber, ayahWordRange: segment.request.ayahWordRange,
            minimumStartFrame: start)
        if let progress, progress.isCompleteLine, let last = progress.matchedEndFrame {
            var emittedFrames: [Int] = []; var previous: Int?
            for (frame, token) in decoded.frameTokenIDs.enumerated() {
                if token != previous && token != 1024 { emittedFrames.append(frame) }
                previous = token
            }
            if let tail = emittedFrames.firstIndex(of: last), tail + 1 >= progress.matchedTokenCount {
                start = max(start, emittedFrames[tail + 1 - progress.matchedTokenCount])
            }
        }
        let end = progress?.isCompleteLine == true ? min(output.timeSteps, (progress?.matchedEndFrame ?? (output.timeSteps-1)) + 2) : output.timeSteps
        guard end > start else { return (output,0) }
        return (OnnxInferenceOutput(logProbabilities: Array(output.logProbabilities[(start*output.vocabularySize)..<(end*output.vocabularySize)]),
            encoderHiddenStates: [], timeSteps: end-start, vocabularySize: output.vocabularySize, encoderHiddenWidth: output.encoderHiddenWidth),start)
    }
    func stop() async throws -> RecitationSummary {
        guard !stopping else { throw OnnxRunnerError.invalidAudio("Stop is already in progress") }
        if stopped { return summary() }
        let stopGeneration = generation
        stopping = true; emitState(.evaluating)
        if let current = worker { await current.value }
        guard stopGeneration == generation else { throw OnnxRunnerError.cancelled }
        // Explicit end-of-input supplies endpoint silence, never words or lexical/acoustic evidence.
        if position < segments.count, voiceStart != nil {
            offer(terminal: true, padded: true)
            if let final = worker { await final.value }
        } else if voiceStart == nil { continuation.yield(.needsRetry(total < 4800 ? .tooShort : .noise)) }
        guard stopGeneration == generation else { throw OnnxRunnerError.cancelled }
        stopped = true; stopping = false; emitState(.ended)
        if let lastError { throw lastError }
        return summary()
    }
    private func summary() -> RecitationSummary {
        RecitationSummary(verses: verses, transcript: acceptedText.isEmpty ? transcript : acceptedText.joined(separator: " "), duration: Double(total) / 16000)
    }
    private func emitState(_ next: RecognitionState) {
        if state != next { state = next; continuation.yield(.state(next)) }
    }
}

extension QuranTokenCatalog {
    static func bundled() throws -> QuranTokenCatalog {
        try QuranTokenCatalog(resourceURL: Bundle.module.url(forResource: resourceName, withExtension: resourceExtension)!)
    }
}
