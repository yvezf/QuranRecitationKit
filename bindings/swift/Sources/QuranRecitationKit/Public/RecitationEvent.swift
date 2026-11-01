import Foundation

public struct WordProgress: Sendable, Equatable {
    public let surah: Int
    public let ayah: Int
    /// Zero-based position within the complete ayah.
    public let wordIndex: Int
    public let totalWords: Int
    public let matchedWordIndices: Set<Int>
    /// Model support, not a calibrated probability of correct pronunciation.
    public let confidence: Double
}
public struct VerseMatch: Sendable, Equatable {
    public let surah: Int
    public let ayah: Int
    public let confidence: Double
    public let durationSeconds: TimeInterval
}
public struct RawTranscript: Sendable, Equatable {
    public let text: String
    public let confidence: Double
}
public enum RetryReason: String, Sendable, Equatable {
    case inconclusive, offTarget, noise, tooShort
}
public enum RecognitionState: String, Sendable, Equatable {
    case idle, listening, evaluating, ended
}
public enum RecitationEvent: Sendable, Equatable {
    case wordProgress(WordProgress)
    case verseMatch(VerseMatch)
    case needsRetry(RetryReason)
    case rawTranscript(RawTranscript)
    case state(RecognitionState)
}
