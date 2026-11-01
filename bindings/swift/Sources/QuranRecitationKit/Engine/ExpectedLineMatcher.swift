import Foundation

enum QuranExpectedLineMatchIgnoredReason: Equatable, Sendable {
    case differentSession
    case staleOrDuplicateSequence
    case wrongVerse
    case inconsistentTotalWordCount
    case invalidOneBasedWordIndex
    case invalidMatchedWordIndex
    case noNewEvidence
}

enum QuranExpectedLineMatchResult: Equatable, Sendable {
    case accepted(InternalLineProgress)
    case ignored(QuranExpectedLineMatchIgnoredReason)
}

/// Converts provider observations into monotonic, line-scoped progress.
///
/// The matcher does not infer missing words from `wordIndexOneBased`. Only
/// explicitly matched indices are accumulated, and only their longest
/// contiguous prefix from the requested line's lower bound is creditable.
/// This makes growth fail closed when recognition skips a word.
struct ExpectedLineMatcher: Sendable {
    private(set) var request: RecognitionRequest
    private(set) var lastSeenSequence: UInt64?
    private(set) var cumulativeMatchedWordIndices: Set<Int> = []

    init(request: RecognitionRequest) {
        self.request = request
    }

    mutating func reset(to request: RecognitionRequest) {
        self.request = request
        lastSeenSequence = nil
        cumulativeMatchedWordIndices.removeAll(keepingCapacity: true)
    }

    mutating func consume(
        _ observation: InternalWordProgressObservation
    ) -> QuranExpectedLineMatchResult {
        guard observation.sessionID == request.sessionID else {
            return .ignored(.differentSession)
        }

        guard lastSeenSequence.map({ observation.sequence > $0 }) ?? true else {
            return .ignored(.staleOrDuplicateSequence)
        }

        // Sequence numbers order the provider stream, not merely accepted
        // progress. Record it before checking the verse so a delayed older event
        // cannot be accepted after a newer same-session event was observed.
        lastSeenSequence = observation.sequence

        guard
            observation.surahNumber == request.surahNumber,
            observation.ayahNumber == request.ayahNumber
        else {
            return .ignored(.wrongVerse)
        }

        guard observation.totalWords == request.expectedAyahWordCount else {
            return .ignored(.inconsistentTotalWordCount)
        }

        guard (1...observation.totalWords).contains(observation.wordIndexOneBased) else {
            return .ignored(.invalidOneBasedWordIndex)
        }

        guard observation.matchedWordIndices.allSatisfy({
            (0..<observation.totalWords).contains($0)
        }) else {
            return .ignored(.invalidMatchedWordIndex)
        }

        let evidenceInLine = Set(
            observation.matchedWordIndices.filter(request.ayahWordRange.contains)
        )
        let priorEvidence = cumulativeMatchedWordIndices
        cumulativeMatchedWordIndices.formUnion(evidenceInLine)

        guard cumulativeMatchedWordIndices != priorEvidence else {
            return .ignored(.noNewEvidence)
        }

        var contiguousUpperBound = request.ayahWordRange.lowerBound
        while
            contiguousUpperBound < request.ayahWordRange.upperBound,
            cumulativeMatchedWordIndices.contains(contiguousUpperBound)
        {
            contiguousUpperBound += 1
        }

        let progress = InternalLineProgress(
            sessionID: request.sessionID,
            sequence: observation.sequence,
            surahNumber: request.surahNumber,
            ayahNumber: request.ayahNumber,
            focusWordIndex: observation.wordIndexOneBased - 1,
            lineWordRange: request.ayahWordRange,
            cumulativeMatchedWordIndices: cumulativeMatchedWordIndices,
            contiguousMatchedWordRange: request.ayahWordRange.lowerBound..<contiguousUpperBound
        )
        return .accepted(progress)
    }
}
