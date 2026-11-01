import Foundation
import QRKFFI

/// Mono 16 kHz Float32 expected-text tracking. One shared Rust engine; no network during recognition.
public actor RecitationRecognizer {
    public nonisolated let events: AsyncStream<RecitationEvent>
    /// feed/reset are non-throwing for API compatibility; inspect this if a native transport call fails.
    public private(set) var lastError: RecognitionError?
    private let handle: NativeHandle
    private let bridge: EventBridge
    public init(modelPack: ModelPack, configuration: RecitationConfiguration = .default) async throws {
        let config: [String: Any] = ["live_tracking": configuration.liveTracking,
            "maximum_window_seconds": configuration.maximumWindowSeconds,
            "backtrack_words": configuration.backtrackWords, "lookahead_words": configuration.lookaheadWords,
            "policy": configuration.policy.rawValue]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        var pointer: OpaquePointer?
        try checked(qrk_recognizer_new(modelPack.modelURL.deletingLastPathComponent().path, nil, json, &pointer))
        guard let pointer else { throw RecognitionError(message: "Native handle was not created.") }
        handle = NativeHandle(pointer)
        let stream = AsyncStream<RecitationEvent>.makeStream(bufferingPolicy: .bufferingNewest(512))
        events = stream.stream; bridge = EventBridge(stream.continuation)
    }
    deinit { bridge.continuation.finish() }
    public func setExpected(_ target: RecitationTarget) async throws {
        let value: [String: Any]
        switch target {
        case .surah(let n): value = ["surah": n]
        case .ayahs(let n, let range): value = ["surah": n, "from": range.lowerBound, "to": range.upperBound]
        case .words(let n, let a, let range): value = ["surah": n, "ayah": a, "from": range.lowerBound, "to": range.upperBound]
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        try checked(qrk_set_expected(handle.pointer, json)); lastError = nil
    }
    public func feed(_ pcm16k: [Float]) async {
        do {
            try pcm16k.withUnsafeBufferPointer { samples in
                try checked(qrk_feed(handle.pointer, samples.baseAddress, UInt(samples.count), { json, context in
                    guard let json, let context else { return }
                    Unmanaged<EventBridge>.fromOpaque(context).takeUnretainedValue().accept(String(cString: json))
                }, Unmanaged.passUnretained(bridge).toOpaque()))
            }
            if let error = bridge.takeFailure() { throw error }
        } catch { lastError = RecognitionError(message: error.localizedDescription); bridge.continuation.yield(.needsRetry(.inconclusive)) }
    }
    public func stop() async throws -> RecitationSummary {
        var pointer: UnsafeMutablePointer<CChar>?
        try checked(qrk_stop(handle.pointer, &pointer))
        let json = try ownedString(pointer)
        struct Wire: Decodable {
            struct Verse: Decodable { let surah: Int; let ayah: Int; let confidence: Double; let duration_seconds: Double }
            let verses: [Verse]; let transcript: String; let duration: Double; let events: [WireEvent]
        }
        let result = try JSONDecoder().decode(Wire.self, from: Data(json.utf8))
        for event in result.events { bridge.continuation.yield(try event.event()) }
        return .init(verses: result.verses.map { .init(surah: $0.surah, ayah: $0.ayah, confidence: $0.confidence, durationSeconds: $0.duration_seconds) }, transcript: result.transcript, duration: result.duration)
    }
    public func reset() async {
        do { try checked(qrk_reset(handle.pointer)); lastError = nil; bridge.continuation.yield(.state(.idle)) }
        catch { lastError = RecognitionError(message: error.localizedDescription) }
    }
}
