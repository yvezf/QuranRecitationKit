import Foundation

public struct RecitationSummary: Sendable {
    /// For a `.words` target, a match means that selected range was completed.
    public let verses: [VerseMatch]
    public let transcript: String
    public let duration: TimeInterval
}
