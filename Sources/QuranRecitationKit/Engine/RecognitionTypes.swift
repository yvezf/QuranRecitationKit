import Foundation

/// The Quran location that a recognizer is allowed to advance.
///
/// Word indices are zero-based and ayah-relative. `ayahWordRange` is half-open,
/// matching Swift's `Range` convention and `QuranLine.ayahWordRange`.
struct RecognitionRequest: Equatable, Sendable {
    let sessionID: UUID
    let surahNumber: Int
    let ayahNumber: Int
    let ayahWordRange: Range<Int>
    let expectedAyahWordCount: Int

    init(
        sessionID: UUID,
        surahNumber: Int,
        ayahNumber: Int,
        ayahWordRange: Range<Int>,
        expectedAyahWordCount: Int
    ) throws {
        guard (1...114).contains(surahNumber) else {
            throw InternalRequestValidationError.invalidSurah(surahNumber)
        }
        guard ayahNumber > 0 else {
            throw InternalRequestValidationError.invalidAyah(ayahNumber)
        }
        guard expectedAyahWordCount > 0 else {
            throw InternalRequestValidationError.invalidAyahWordCount(expectedAyahWordCount)
        }
        guard
            ayahWordRange.lowerBound >= 0,
            !ayahWordRange.isEmpty,
            ayahWordRange.upperBound <= expectedAyahWordCount
        else {
            throw InternalRequestValidationError.invalidLineWordRange(
                ayahWordRange,
                ayahWordCount: expectedAyahWordCount
            )
        }

        self.sessionID = sessionID
        self.surahNumber = surahNumber
        self.ayahNumber = ayahNumber
        self.ayahWordRange = ayahWordRange
        self.expectedAyahWordCount = expectedAyahWordCount
    }
}

enum InternalRequestValidationError: Error, Equatable, Sendable {
    case invalidSurah(Int)
    case invalidAyah(Int)
    case invalidAyahWordCount(Int)
    case invalidLineWordRange(Range<Int>, ayahWordCount: Int)
}

/// A provider-neutral representation of 's `word_progress` payload.
///
/// `wordIndexOneBased` deliberately preserves the provider wire convention;
/// the matcher is the single boundary that converts it to a zero-based index.
/// `matchedWordIndices` are zero-based but may be non-cumulative from one
/// observation to the next.
struct InternalWordProgressObservation: Equatable, Sendable {
    let sessionID: UUID
    let sequence: UInt64
    let surahNumber: Int
    let ayahNumber: Int
    let wordIndexOneBased: Int
    let totalWords: Int
    let matchedWordIndices: [Int]
}

/// Display-only feedback for the exact currently expected Quran word.
///
/// This signal never accepts a line or awards  progress. `needsRetry` is
/// deliberately conservative: the on-device service emits it only after an
/// utterance has reached terminal silence and multiple current-marker analyses
/// agree that an acoustically identity-matched expected word began correctly
/// but then diverged. Wrong-line/noise rejection never produces this cue.
enum InternalCurrentWordPronunciation: Equatable, Sendable {
    case unknown
    case tracking
    case needsRetry
}

/// Safe, cumulative progress for exactly one requested Quran display line.
struct InternalLineProgress: Equatable, Sendable {
    let sessionID: UUID
    let sequence: UInt64
    let surahNumber: Int
    let ayahNumber: Int

    /// Ayah-relative, zero-based provider focus after one-based conversion.
    let focusWordIndex: Int

    let lineWordRange: Range<Int>

    /// Cumulative ayah-relative evidence, restricted to `lineWordRange`.
    let cumulativeMatchedWordIndices: Set<Int>

    /// The longest gap-free prefix beginning at `lineWordRange.lowerBound`.
    let contiguousMatchedWordRange: Range<Int>

    /// Display-only exact greedy-token coverage. This is ayah-relative and is
    /// always a gap-free prefix of `lineWordRange`. Unlike the fuzzy word set
    /// above, it can drive continuous karaoke without entering acceptance.
    let completedWordRange: Range<Int>

    /// The next ayah-relative expected word receiving exact token-frame
    /// support. `nil` means every word is complete in the display tracker.
    let currentWordIndex: Int?

    /// Exact matched-token fraction inside `currentWordIndex`. Producers keep
    /// this finite and in `0..<1`; completing a word advances the range/index.
    let currentWordFraction: Double

    let currentWordPronunciation: InternalCurrentWordPronunciation

    /// Display-only, scoped request to retry the whole line. This is distinct
    /// from `needsRetry`: rejected/inconclusive identity never blames a word.
    let lineRetrySuggested: Bool

    init(
        sessionID: UUID,
        sequence: UInt64,
        surahNumber: Int,
        ayahNumber: Int,
        focusWordIndex: Int,
        lineWordRange: Range<Int>,
        cumulativeMatchedWordIndices: Set<Int>,
        contiguousMatchedWordRange: Range<Int>,
        completedWordRange: Range<Int>? = nil,
        currentWordIndex: Int? = nil,
        currentWordFraction: Double = 0,
        currentWordPronunciation: InternalCurrentWordPronunciation = .unknown,
        lineRetrySuggested: Bool = false
    ) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.surahNumber = surahNumber
        self.ayahNumber = ayahNumber
        self.focusWordIndex = focusWordIndex
        self.lineWordRange = lineWordRange
        self.cumulativeMatchedWordIndices = cumulativeMatchedWordIndices
        self.contiguousMatchedWordRange = contiguousMatchedWordRange

        let suppliedUpperBound = completedWordRange?.upperBound
            ?? contiguousMatchedWordRange.upperBound
        let completedUpperBound = min(
            max(suppliedUpperBound, lineWordRange.lowerBound),
            lineWordRange.upperBound
        )
        self.completedWordRange = lineWordRange.lowerBound..<completedUpperBound

        let resolvedCurrentWordIndex = currentWordIndex.flatMap {
            lineWordRange.contains($0) && $0 == completedUpperBound ? $0 : nil
        }
        self.currentWordIndex = resolvedCurrentWordIndex
        if resolvedCurrentWordIndex == nil || !currentWordFraction.isFinite {
            self.currentWordFraction = 0
        } else {
            // A value of one belongs in `completedWordRange`; keep a current
            // partial strictly below that boundary even for defensive callers.
            self.currentWordFraction = min(
                max(currentWordFraction, 0),
                Double(1).nextDown
            )
        }
        self.currentWordPronunciation = currentWordPronunciation
        self.lineRetrySuggested = lineRetrySuggested
    }

    var matchedLineWordCount: Int {
        contiguousMatchedWordRange.count
    }

    var totalLineWordCount: Int {
        lineWordRange.count
    }

    var fraction: Double {
        guard totalLineWordCount > 0 else { return 0 }
        return Double(matchedLineWordCount) / Double(totalLineWordCount)
    }

    var isLineReady: Bool {
        contiguousMatchedWordRange.upperBound == lineWordRange.upperBound
    }
}

enum InternalRecognitionState: Equatable, Sendable {
    case idle
    case preparing
    case listening
    case matchingExpectedAyah
    case trackingWords
    case lineReady
    case stopped
    case failed(RecognitionFailure)
}

struct RecognitionFailure: Error, Equatable, Sendable {
    enum Code: String, Equatable, Sendable {
        case permissionDenied
        case audioUnavailable
        case resourceUnavailable
        case modelUnavailable
        case incompatibleResource
        case inferenceFailed
        case interrupted
        case unknown
    }

    let code: Code
    let message: String
}

enum InternalRecognitionEvent: Equatable, Sendable {
    case stateChanged(InternalRecognitionState)
    case wordProgress(InternalLineProgress)
    case failed(RecognitionFailure)
}
