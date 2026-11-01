import Foundation

/// An expected-text recognizer. Feed mono 16 kHz Float32 PCM; no capture or UI is owned here.
public actor RecitationRecognizer {
    public nonisolated let events: AsyncStream<RecitationEvent>
    private let session: RecognitionSession
    public init(modelPack: ModelPack, configuration: RecitationConfiguration = .default) async throws {
        let runner = OnnxRunner(modelURL: modelPack.modelURL, includesEncoderHiddenStates: false)
        try await runner.prepare()
        let stream = AsyncStream<RecitationEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        events = stream.stream
        session = try RecognitionSession(runner: runner, configuration: configuration, continuation: stream.continuation)
    }
    /// Internal dependency injection keeps all unit tests independent of model files and audio.
    init(runner: any AcousticModelRunning, configuration: RecitationConfiguration = .default) throws {
        let stream = AsyncStream<RecitationEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        events = stream.stream
        session = try RecognitionSession(runner: runner, configuration: configuration, continuation: stream.continuation)
    }
    public func setExpected(_ target: RecitationTarget) async throws { try await session.setExpected(target) }
    public func feed(_ pcm16k: [Float]) async { await session.feed(pcm16k) }
    public func stop() async throws -> RecitationSummary { try await session.stop() }
    public func reset() async { await session.reset() }
}
