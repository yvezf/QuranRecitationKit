import AVFoundation
import Foundation

/// Optional microphone adapter. The host supplies its own usage-description string.
/// Stop before changing routes or sessions; create/restart capture after the route stabilizes.
public final class RecitationMicrophone: @unchecked Sendable {
    public let inputLevel: AsyncStream<Float>
    private let levels: AsyncStream<Float>.Continuation
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let lifecycleLock = NSRecursiveLock()
    private var generation: UInt64 = 0
    private var worker: Task<Void, Never>?
    private var audioContinuation: AsyncStream<[Float]>.Continuation?
    private var running = false
    private var tapInstalled = false
    private var resampler: AudioResampler?
    private var observers: [NSObjectProtocol] = []
#if os(iOS)
    private let session: AVAudioSession
    public init(session: AVAudioSession? = nil) throws {
        self.session = session ?? .sharedInstance()
        let stream = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(1))
        inputLevel = stream.stream; levels = stream.continuation
    }
#else
    public init() throws {
        let stream = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(1))
        inputLevel = stream.stream; levels = stream.continuation
    }
#endif
    deinit { stop(); worker?.cancel(); levels.finish() }
    public func start(_ onChunk: @escaping @Sendable ([Float]) async -> Void) async throws {
        let epoch = withLifecycle { () -> UInt64 in stop(); worker?.cancel(); worker = nil; return generation }
#if os(iOS)
        let allowed: Bool
        switch session.recordPermission {
        case .granted: allowed = true
        case .denied: allowed = false
        default: allowed = await withCheckedContinuation { c in session.requestRecordPermission { c.resume(returning: $0) } }
        }
        guard allowed else { throw MicrophoneError.permissionDenied }
#else
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let allowed = status == .authorized ? true : status == .notDetermined ? await AVCaptureDevice.requestAccess(for: .audio) : false
        guard allowed else { throw MicrophoneError.permissionDenied }
#endif
        try withLifecycle {
        guard generation == epoch else { throw CancellationError() }
#if os(iOS)
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setPreferredSampleRate(16000)
        try session.setActive(true)
#endif
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicrophoneError.unavailable }
        let stream = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(64))
        withLock {
            resampler = AudioResampler(inputSampleRate: format.sampleRate)
            running = true; audioContinuation = stream.continuation
        }
        worker = Task {
            for await chunk in stream.stream {
                if Task.isCancelled { break }
                await onChunk(chunk)
            }
        }
        input.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in self?.receive(buffer) }
        tapInstalled = true
        do { engine.prepare(); try engine.start() }
        catch { stop(); throw error }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.stop() }
        })
#if os(iOS)
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] _ in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.stop() }
        })
#endif
        }
    }
    public func stop() {
        withLifecycle {
        generation &+= 1
        let shouldStop = withLock { () -> Bool in
            let result = running; running = false
            audioContinuation?.finish(); audioContinuation = nil; resampler = nil
            return result
        }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        if shouldStop { engine.stop() }
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        levels.yield(0)
        // The host owns audio-session policy, including when to deactivate/reactivate it.
        }
    }
    /// Stop capture and wait for already queued callbacks before calling recognizer.stop().
    /// The synchronous stop() remains available for immediate interruption handling.
    public func stopAndDrain() async {
        let pending = withLifecycle { () -> Task<Void, Never>? in stop(); return worker }
        await pending?.value
    }
    private func receive(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength); let channelCount = Int(buffer.format.channelCount)
        guard count > 0 else { return }
        var mono = [Float](repeating: 0, count: count)
        for channel in 0..<channelCount {
            for i in 0..<count { mono[i] += channels[channel][i] / Float(channelCount) }
        }
        let rms = sqrt(mono.reduce(Float(0)) { $0 + $1*$1 } / Float(count))
        withLock {
            guard running else { return }
            let chunk = resampler?.process(mono) ?? []
            if !chunk.isEmpty { audioContinuation?.yield(chunk) }
        }
        levels.yield(min(1, rms * 12))
    }
    private func withLifecycle<T>(_ body: () throws -> T) rethrows -> T {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }; return try body()
    }
    private func withLock<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}
public enum MicrophoneError: Error, LocalizedError {
    case permissionDenied, unavailable
    public var errorDescription: String? {
        switch self { case .permissionDenied: return "Microphone permission was not granted."
        case .unavailable: return "No usable microphone input is available." }
    }
}
