import Foundation

public struct RecitationConfiguration: Sendable {
    public enum Policy: String, Sendable { case balanced, conservative, lenient }
    public let liveTracking: Bool
    /// Retained PCM is always bounded by the model's 12-second contract.
    public let maximumWindowSeconds: Double
    public let backtrackWords: Int
    public let lookaheadWords: Int
    public let policy: Policy
    public init(liveTracking: Bool = true, maximumWindowSeconds: Double = 12,
                backtrackWords: Int = 3, lookaheadWords: Int = 32, policy: Policy = .balanced) {
        self.liveTracking = liveTracking
        self.maximumWindowSeconds = maximumWindowSeconds.isFinite ? min(12, max(2, maximumWindowSeconds)) : 12
        self.backtrackWords = min(32, max(0, backtrackWords))
        self.lookaheadWords = min(128, max(1, lookaheadWords))
        self.policy = policy
    }
    /// The shipped legacy word/CTC/endpoint thresholds, without experimental continuous authority.
    public static let `default` = Self()
    public static let balanced = Self()
    public static let conservative = Self(policy: .conservative)
    public static let lenient = Self(policy: .lenient)
}
