import CryptoKit
import Foundation

#if DEBUG
import OSLog
#endif

#if canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings
#endif

/// The immutable release contract for 's raw-audio acoustic model.
///
/// Keep this metadata beside the runner instead of trusting a similarly named
/// otherwise produce plausible-looking but meaningless CTC scores.
struct ModelMetadata: Equatable, Sendable {
    let modelFileName: String
    let modelByteCount: Int64
    let modelSHA256: String
    let audioInputName: String
    let lengthInputName: String
    let logProbabilitiesOutputName: String
    let encoderHiddenOutputName: String
    let expectedVocabularySize: Int
    let expectedEncoderHiddenWidth: Int
    let expectedSampleRate: Int
    let maximumSampleCount: Int

    static let releaseV1 = ModelMetadata(
        modelFileName: "fastconformer_full_mixed.onnx",
        modelByteCount: 88_307_457,
        modelSHA256: "822534428f1ed54eb802a9c43d4ecbabdfd8ba346b4d88d710414b0bbe7b4d69",
        audioInputName: "audio_signal",
        lengthInputName: "length",
        logProbabilitiesOutputName: "log_probs",
        encoderHiddenOutputName: "/encoder/layers.16/norm_out/LayerNormalization_output_0",
        expectedVocabularySize: 1_025,
        expectedEncoderHiddenWidth: 512,
        expectedSampleRate: 16_000,
        maximumSampleCount: 16_000 * 12
    )
}

/// Latency controls that do not alter the calibrated recognition policy.
/// The relay still requires exactly 3,200 fresh 16 kHz samples before it emits
/// a snapshot; the shorter poll only reduces scheduling phase delay.
enum LiveLatencyTuning {
    static let readinessPollNanoseconds: UInt64 = 12_000_000
    static let audioTapBufferSize: UInt32 = 512
    /// Keep authoritative continuous provisional recognition cheap enough to
    /// calibrated window; the relay retains 12 seconds for terminal recovery.
    /// The two-second live suffix is the on-device benchmark's fastest warm
    /// input and lets the latest-only mailbox publish acoustic paint instead
    /// of spending the next spoken word finishing a stale four-second pass.
    static let maximumLiveModelSampleCount = 16_000 * 2
}

/// One model forward pass. CTC values are already log-softmaxed and stored in
/// row-major `[timeSteps, vocabularySize]` order. Encoder values share the
/// exact same time axis and use row-major `[timeSteps, encoderHiddenWidth]`.
struct OnnxInferenceOutput: Sendable {
    let logProbabilities: [Float]
    let encoderHiddenStates: [Float]
    let timeSteps: Int
    let vocabularySize: Int
    let encoderHiddenWidth: Int
}

enum OnnxRunnerError: Error, Equatable {
    case runtimeUnavailable
    case invalidMetadata(String)
    case modelMissing(String)
    case modelIsNotARegularFile(String)
    case modelFileNameMismatch(expected: String, actual: String)
    case modelSizeMismatch(expected: Int64, actual: Int64)
    case modelHashMismatch(expected: String, actual: String)
    case modelReadFailed(String)
    case sessionCreationFailed(String)
    case invalidAudio(String)
    case inferenceSuperseded
    case cancelled
    case runnerInvalidated
    case inferenceFailed(String)
    case missingOutput(String)
    case invalidOutputShape([Int])
    case vocabularyMismatch(expected: Int, actual: Int)
    case encoderHiddenWidthMismatch(expected: Int, actual: Int)
    case outputTimeStepMismatch(logProbabilities: Int, encoderHidden: Int)
    case outputByteCountMismatch(expected: Int, actual: Int)
}

extension OnnxRunnerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            return "Microsoft ONNX Runtime is not linked into this build."
        case let .invalidMetadata(reason):
            return " model metadata is invalid: \(reason)"
        case let .modelMissing(path):
            return " model is missing at \(path)."
        case let .modelIsNotARegularFile(path):
            return " model is not a regular readable file at \(path)."
        case let .modelFileNameMismatch(expected, actual):
            return " model filename mismatch (expected \(expected), found \(actual))."
        case let .modelSizeMismatch(expected, actual):
            return " model size mismatch (expected \(expected) bytes, found \(actual))."
        case let .modelHashMismatch(expected, actual):
            return " model SHA-256 mismatch (expected \(expected), found \(actual))."
        case let .modelReadFailed(reason):
            return " model could not be read: \(reason)"
        case let .sessionCreationFailed(reason):
            return " ONNX session could not be created: \(reason)"
        case let .invalidAudio(reason):
            return " received invalid audio: \(reason)"
        case .inferenceSuperseded:
            return "A newer  audio window superseded this pending inference."
        case .cancelled:
            return " inference was cancelled."
        case .runnerInvalidated:
            return " ONNX runner has been invalidated."
        case let .inferenceFailed(reason):
            return " inference failed: \(reason)"
        case let .missingOutput(name):
            return " model did not return its \(name) output."
        case let .invalidOutputShape(shape):
            return " returned an invalid output shape: \(shape)."
        case let .vocabularyMismatch(expected, actual):
            return " vocabulary mismatch (expected \(expected), found \(actual))."
        case let .encoderHiddenWidthMismatch(expected, actual):
            return " encoder width mismatch (expected \(expected), found \(actual))."
        case let .outputTimeStepMismatch(logProbabilities, encoderHidden):
            return " output frame mismatch (CTC \(logProbabilities), encoder \(encoderHidden))."
        case let .outputByteCountMismatch(expected, actual):
            return " output byte count mismatch (expected \(expected), found \(actual))."
        }
    }
}

/// Small value-type FIFO used to bound asynchronous work without coupling its
/// ordering tests to ONNX Runtime. `append` and `drain` remove elements from
/// storage before returning them, so callers can safely resume continuations
struct BoundedFIFO<Element> {
    let capacity: Int
    private var storage: [Element] = []

    init(capacity: Int) {
        precondition(capacity > 0, "BoundedFIFO capacity must be positive")
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }

    /// Appends at the tail and returns the dropped oldest element, if any.
    @discardableResult
    mutating func append(_ element: Element) -> Element? {
        storage.append(element)
        guard storage.count > capacity else { return nil }
        return storage.removeFirst()
    }

    /// Removes the oldest retained element.
    mutating func popFirst() -> Element? {
        guard !storage.isEmpty else { return nil }
        return storage.removeFirst()
    }

    /// Removes and returns all retained elements in oldest-to-newest order.
    mutating func drain() -> [Element] {
        let drained = storage
        storage.removeAll(keepingCapacity: true)
        return drained
    }
}

/// Two-slot handoff between the inexpensive audio-readiness poller and the
/// single completion-driven model consumer. The newest policy-window snapshot
/// is always consumed before the terminal (>2 second silence) observation, so
/// a slow inference cannot let a later terminal snapshot erase the last real
/// opportunity to satisfy the calibrated endpoint policy.
struct NewestSnapshotMailbox<Element> {
    private var newestInPolicyWindow: Element?
    private var terminal: Element?

    var count: Int {
        (newestInPolicyWindow == nil ? 0 : 1) + (terminal == nil ? 0 : 1)
    }

    var isEmpty: Bool { count == 0 }

    mutating func offer(_ element: Element, isTerminal: Bool) {
        if isTerminal {
            terminal = element
        } else {
            // A new in-window observation after a terminal one implies fresh
            // voice. The older terminal observation belongs to the prior
            // marker and must not be replayed after the new utterance.
            newestInPolicyWindow = element
            terminal = nil
        }
    }

    mutating func takeNext() -> Element? {
        if let newestInPolicyWindow {
            self.newestInPolicyWindow = nil
            return newestInPolicyWindow
        }
        if let terminal {
            self.terminal = nil
            return terminal
        }
        return nil
    }

    mutating func removeAll() {
        newestInPolicyWindow = nil
        terminal = nil
    }
}

struct SharedTaskWaiterLease: Hashable, Sendable {
    let generation: UInt64
    let waiterID: UInt64
}

struct SharedTaskLeaseRelease: Equatable, Sendable {
    let wasActive: Bool
    let remainingWaiterCount: Int
    let shouldCancelCurrentTask: Bool
}

/// Pure generation-scoped waiter accounting for cancellable shared setup.
/// Releasing an old lease can never cancel a replacement generation.
struct SharedTaskLeaseLedger {
    private(set) var currentGeneration: UInt64 = 0
    private var nextWaiterID: UInt64 = 0
    private var waiters: [UInt64: Set<UInt64>] = [:]

    mutating func beginGeneration() -> UInt64 {
        currentGeneration &+= 1
        return currentGeneration
    }

    mutating func acquire(
        generation: UInt64
    ) -> SharedTaskWaiterLease {
        nextWaiterID &+= 1
        let lease = SharedTaskWaiterLease(
            generation: generation,
            waiterID: nextWaiterID
        )
        waiters[generation, default: []].insert(lease.waiterID)
        return lease
    }

    func waiterCount(generation: UInt64) -> Int {
        waiters[generation]?.count ?? 0
    }

    mutating func release(
        _ lease: SharedTaskWaiterLease
    ) -> SharedTaskLeaseRelease {
        guard var generationWaiters = waiters[lease.generation],
              generationWaiters.remove(lease.waiterID) != nil else {
            return SharedTaskLeaseRelease(
                wasActive: false,
                remainingWaiterCount: waiters[lease.generation]?.count ?? 0,
                shouldCancelCurrentTask: false
            )
        }
        if generationWaiters.isEmpty {
            waiters.removeValue(forKey: lease.generation)
        } else {
            waiters[lease.generation] = generationWaiters
        }
        return SharedTaskLeaseRelease(
            wasActive: true,
            remainingWaiterCount: generationWaiters.count,
            shouldCancelCurrentTask: generationWaiters.isEmpty
                && lease.generation == currentGeneration
        )
    }
}

/// A bounded-tail ONNX runner for 's 16 kHz mono PCM model.
///
/// ONNX Runtime objects stay on one serial queue. While a pass is executing,
/// exactly the newest later microphone window is retained. A still newer window
/// replaces that pending value and resumes its caller with `inferenceSuperseded`.
/// Terminal stability cycles are sample-domain observations in the 
/// service, so retaining older full-model work would add latency, not evidence.
final class OnnxRunner: @unchecked Sendable {
    private final class PendingInference: @unchecked Sendable {
        let generation: UInt64
        let audio: [Float]
        let enqueuedUptime: TimeInterval
        let continuation: CheckedContinuation<OnnxInferenceOutput, Error>

        init(
            generation: UInt64,
            audio: [Float],
            enqueuedUptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
            continuation: CheckedContinuation<OnnxInferenceOutput, Error>
        ) {
            self.generation = generation
            self.audio = audio
            self.enqueuedUptime = enqueuedUptime
            self.continuation = continuation
        }
    }

    static let maximumPendingInferenceCount = 1
    /// Frozen from the on-device Debug benchmark: four intra-op threads ran
    /// 2-second warm windows faster than one or two, and also led at 4/12 sec.
    /// like 2 seconds later its kareoke-fied"). iPhones have two performance
    /// cores; ONNX Runtime's intra-op pool splits every kernel across all
    /// its threads and waits at a barrier for the slowest shard, so the two
    /// extra threads landing on efficiency cores made each pass wait on
    /// them — and left nothing for the render thread. Two threads pin the
    /// work to the fast cores; latency drops and, above all, stops varying.
    static let defaultIntraOpThreadCount = 2

#if DEBUG
    private static let diagnosticsLogger = Logger(
        subsystem: "QuranRecitationKit",
        category: "Inference"
    )
#endif

    let modelURL: URL
    let metadata: ModelMetadata

    private let intraOpThreadCount: Int32
    private let includesEncoderHiddenStates: Bool
    private let stateQueue = DispatchQueue(label: "QuranRecitationKit.onnx.state", qos: .userInitiated)
    private let inferenceQueue = DispatchQueue(
        label: "QuranRecitationKit.onnx.inference",
        qos: .userInitiated
    )

    private var generation: UInt64 = 0
    private var isInferenceInFlight = false
    /// Accessed only by `stateQueue`. The running request is not in this FIFO.
    private var pendingInferences = BoundedFIFO<PendingInference>(
        capacity: OnnxRunner.maximumPendingInferenceCount
    )
    private var isInvalidated = false

#if canImport(OnnxRuntimeBindings)
    /// Accessed only by `inferenceQueue`.
    private var environment: ORTEnv?
    /// Accessed only by `inferenceQueue`.
    private var session: ORTSession?
#endif

    init(
        modelURL: URL,
        metadata: ModelMetadata = .releaseV1,
        intraOpThreadCount: Int = OnnxRunner.defaultIntraOpThreadCount,
        includesEncoderHiddenStates: Bool = true
    ) {
        self.modelURL = modelURL
        self.metadata = metadata
        self.intraOpThreadCount = Int32(min(max(intraOpThreadCount, 1), 4))
        self.includesEncoderHiddenStates = includesEncoderHiddenStates
    }

    /// Validates the pinned release file and creates the ONNX session. Calling
    /// this is optional; the first `run` lazily performs the same preparation.
    func prepare() async throws {
        let startedUptime = ProcessInfo.processInfo.systemUptime
        let requestGeneration = try stateQueue.sync { () throws -> UInt64 in
            guard !isInvalidated else {
                throw OnnxRunnerError.runnerInvalidated
            }
            return generation
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            inferenceQueue.async { [self] in
                let result = Result { try prepareOnInferenceQueue() }
                stateQueue.async { [self] in
                    if isInvalidated {
                        continuation.resume(throwing: OnnxRunnerError.runnerInvalidated)
                    } else if requestGeneration != generation {
                        continuation.resume(throwing: OnnxRunnerError.cancelled)
                    } else {
                        continuation.resume(with: result)
                    }
                }
            }
        }
#if DEBUG
        let elapsedMilliseconds = max(
            0,
            (ProcessInfo.processInfo.systemUptime - startedUptime) * 1_000
        )
        let summary = "prepare_ms=\(elapsedMilliseconds)"
        Self.diagnosticsLogger.debug("\(summary, privacy: .public)")
        NSLog("[Inference] %@", summary)
#endif
    }

    /// Runs a raw waveform shaped `[1, N]`; the length tensor is `[N]` as an
    /// `Int64[1]`. Audio must already be mono Float32 PCM at 16 kHz.
    func run(monoPCM16kHz audio: [Float]) async throws -> OnnxInferenceOutput {
        try validateAudio(audio)

        return try await withCheckedThrowingContinuation { continuation in
            stateQueue.async { [self] in
                guard !isInvalidated else {
                    continuation.resume(throwing: OnnxRunnerError.runnerInvalidated)
                    return
                }

                let request = PendingInference(
                    generation: generation,
                    audio: audio,
                    continuation: continuation
                )

                guard isInferenceInFlight else {
                    isInferenceInFlight = true
                    execute(request)
                    return
                }

                if let superseded = pendingInferences.append(request) {
#if DEBUG
                    let summary = "coalesce pending=\(self.pendingInferences.count) input_samples=\(audio.count)"
                    Self.diagnosticsLogger.debug("\(summary, privacy: .public)")
                    NSLog("[Inference] %@", summary)
#endif
                    superseded.continuation.resume(
                        throwing: OnnxRunnerError.inferenceSuperseded
                    )
                }
            }
        }
    }

    /// Cancels any queued window and makes an already-running result stale.
    /// The ONNX call itself is allowed to finish because interrupting the native
    /// session is not reliably safe; the runner can immediately accept a newer
    /// window, which will execute next.
    func cancelPendingInference() {
        stateQueue.sync {
            generation &+= 1
            let cancelled = pendingInferences.drain()
            for request in cancelled {
                request.continuation.resume(throwing: OnnxRunnerError.cancelled)
            }
        }
    }

    /// Permanently rejects new work and cancels all results not yet delivered.
    func invalidate() {
        stateQueue.sync {
            guard !isInvalidated else { return }
            isInvalidated = true
            generation &+= 1
            let invalidated = pendingInferences.drain()
            for request in invalidated {
                request.continuation.resume(
                    throwing: OnnxRunnerError.runnerInvalidated
                )
            }
        }
    }

    static func validateModelFile(
        at url: URL,
        metadata: ModelMetadata = .releaseV1
    ) throws {
        guard metadata.expectedVocabularySize > 0,
              metadata.expectedSampleRate > 0,
              metadata.maximumSampleCount > 0,
              metadata.modelByteCount > 0,
              metadata.expectedEncoderHiddenWidth > 0,
              !metadata.encoderHiddenOutputName.isEmpty else {
            throw OnnxRunnerError.invalidMetadata("numeric values must be positive")
        }

        let expectedHash = metadata.modelSHA256.lowercased()
        let isHexHash = expectedHash.count == 64
            && expectedHash.unicodeScalars.allSatisfy {
                (48...57).contains($0.value) || (97...102).contains($0.value)
            }
        guard isHexHash else {
            throw OnnxRunnerError.invalidMetadata("model SHA-256 must be 64 hexadecimal characters")
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OnnxRunnerError.modelMissing(url.path)
        }
        guard url.lastPathComponent == metadata.modelFileName else {
            throw OnnxRunnerError.modelFileNameMismatch(
                expected: metadata.modelFileName,
                actual: url.lastPathComponent
            )
        }

        let resourceValues: URLResourceValues
        do {
            resourceValues = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isReadableKey,
                .fileSizeKey
            ])
        } catch {
            throw OnnxRunnerError.modelReadFailed(error.localizedDescription)
        }

        guard resourceValues.isRegularFile == true,
              resourceValues.isReadable == true else {
            throw OnnxRunnerError.modelIsNotARegularFile(url.path)
        }

        let actualByteCount = Int64(resourceValues.fileSize ?? -1)
        guard actualByteCount == metadata.modelByteCount else {
            throw OnnxRunnerError.modelSizeMismatch(
                expected: metadata.modelByteCount,
                actual: actualByteCount
            )
        }

        let actualHash = try sha256Hex(of: url)
        guard actualHash == expectedHash else {
            throw OnnxRunnerError.modelHashMismatch(
                expected: expectedHash,
                actual: actualHash
            )
        }
    }

    private func validateAudio(_ audio: [Float]) throws {
        guard !audio.isEmpty else {
            throw OnnxRunnerError.invalidAudio("the waveform is empty")
        }
        guard audio.count <= metadata.maximumSampleCount else {
            throw OnnxRunnerError.invalidAudio(
                "\(audio.count) samples exceeds the \(metadata.maximumSampleCount)-sample rolling-window limit"
            )
        }
        guard audio.allSatisfy(\.isFinite) else {
            throw OnnxRunnerError.invalidAudio("the waveform contains a non-finite sample")
        }
    }

    private func execute(_ request: PendingInference) {
        inferenceQueue.async { [self] in
            let startedUptime = ProcessInfo.processInfo.systemUptime
            let result = Result { try runOnInferenceQueue(audio: request.audio) }
            let finishedUptime = ProcessInfo.processInfo.systemUptime
#if DEBUG
            let succeeded: Bool
            switch result {
            case .success:
                succeeded = true
            case .failure:
                succeeded = false
            }
            let queuedMilliseconds = max(
                0,
                (startedUptime - request.enqueuedUptime) * 1_000
            )
            let inferenceMilliseconds = max(
                0,
                (finishedUptime - startedUptime) * 1_000
            )
            let inputMilliseconds = Double(request.audio.count)
                / Double(metadata.expectedSampleRate) * 1_000
            let summary = "run input_ms=\(inputMilliseconds) queue_ms=\(queuedMilliseconds) inference_ms=\(inferenceMilliseconds) success=\(succeeded)"
            Self.diagnosticsLogger.debug("\(summary, privacy: .public)")
            NSLog("[Inference] %@", summary)
#endif

            stateQueue.async { [self] in
                if isInvalidated {
                    request.continuation.resume(
                        throwing: OnnxRunnerError.runnerInvalidated
                    )
                } else if request.generation != generation {
                    request.continuation.resume(throwing: OnnxRunnerError.cancelled)
                } else {
                    request.continuation.resume(with: result)
                }

                if isInvalidated {
                    isInferenceInFlight = false
                    return
                }

                if let next = pendingInferences.popFirst() {
                    execute(next)
                } else {
                    isInferenceInFlight = false
                }
            }
        }
    }

    /// Must only be called from `inferenceQueue`.
    private func prepareOnInferenceQueue() throws {
#if canImport(OnnxRuntimeBindings)
        guard session == nil else { return }
        try Self.validateModelFile(at: modelURL, metadata: metadata)

        do {
            let environment = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(intraOpThreadCount)
            // Sleeping workers leave the render/main threads a core between
            // kernels. This changes scheduling, not model math or its gates.
            try options.addConfigEntry(withKey: "session.intra_op.allow_spinning", value: "0")
            let session = try ORTSession(
                env: environment,
                modelPath: modelURL.path,
                sessionOptions: options
            )

            // ORTSession retains the environment in current releases, but keep
            // an explicit strong reference to make that lifetime requirement
            // unambiguous at the Swift/Objective-C boundary.
            self.environment = environment
            self.session = session
        } catch let error as OnnxRunnerError {
            throw error
        } catch {
            throw OnnxRunnerError.sessionCreationFailed(error.localizedDescription)
        }
#else
        throw OnnxRunnerError.runtimeUnavailable
#endif
    }

    /// Must only be called from `inferenceQueue`.
    private func runOnInferenceQueue(audio: [Float]) throws -> OnnxInferenceOutput {
        try prepareOnInferenceQueue()

#if canImport(OnnxRuntimeBindings)
        guard let session else {
            throw OnnxRunnerError.sessionCreationFailed("session was not retained")
        }

        do {
            let audioData = audio.withUnsafeBufferPointer { buffer in
                NSMutableData(
                    bytes: buffer.baseAddress,
                    length: buffer.count * MemoryLayout<Float>.size
                )
            }
            let audioTensor = try ORTValue(
                tensorData: audioData,
                elementType: .float,
                shape: [1, NSNumber(value: audio.count)]
            )

            var sampleCount = Int64(audio.count)
            let lengthData = NSMutableData(
                bytes: &sampleCount,
                length: MemoryLayout<Int64>.size
            )
            let lengthTensor = try ORTValue(
                tensorData: lengthData,
                elementType: .int64,
                shape: [1]
            )

            let outputs = try session.run(
                withInputs: [
                    metadata.audioInputName: audioTensor,
                    metadata.lengthInputName: lengthTensor
                ],
                outputNames: includesEncoderHiddenStates
                    ? Set([metadata.logProbabilitiesOutputName, metadata.encoderHiddenOutputName])
                    : Set([metadata.logProbabilitiesOutputName]),
                runOptions: nil
            )

            guard let output = outputs[metadata.logProbabilitiesOutputName] else {
                throw OnnxRunnerError.missingOutput(
                    metadata.logProbabilitiesOutputName
                )
            }

            let shape = try output.tensorTypeAndShapeInfo().shape.map(\.intValue)
            guard shape.count == 3,
                  shape[0] == 1,
                  shape[1] > 0,
                  shape[2] > 0 else {
                throw OnnxRunnerError.invalidOutputShape(shape)
            }

            let timeSteps = shape[1]
            let vocabularySize = shape[2]
            guard vocabularySize == metadata.expectedVocabularySize else {
                throw OnnxRunnerError.vocabularyMismatch(
                    expected: metadata.expectedVocabularySize,
                    actual: vocabularySize
                )
            }

            let (floatCount, countOverflow) = timeSteps.multipliedReportingOverflow(
                by: vocabularySize
            )
            let (expectedByteCount, byteOverflow) = floatCount.multipliedReportingOverflow(
                by: MemoryLayout<Float>.size
            )
            guard !countOverflow, !byteOverflow else {
                throw OnnxRunnerError.invalidOutputShape(shape)
            }

            let outputData = try output.tensorData() as Data
            guard outputData.count == expectedByteCount else {
                throw OnnxRunnerError.outputByteCountMismatch(
                    expected: expectedByteCount,
                    actual: outputData.count
                )
            }

            var logProbabilities = [Float](repeating: 0, count: floatCount)
            logProbabilities.withUnsafeMutableBytes { destination in
                _ = outputData.copyBytes(to: destination)
            }
            guard logProbabilities.allSatisfy(\.isFinite) else {
                throw OnnxRunnerError.inferenceFailed(
                    "log_probs contains a non-finite value"
                )
            }

            // The live CTC consumer never reads encoder states. Harnesses
            // retain the full output contract by default for calibration.
            guard includesEncoderHiddenStates else {
                return OnnxInferenceOutput(
                    logProbabilities: logProbabilities,
                    encoderHiddenStates: [],
                    timeSteps: timeSteps,
                    vocabularySize: vocabularySize,
                    encoderHiddenWidth: 0
                )
            }
            guard let encoderHiddenOutput = outputs[metadata.encoderHiddenOutputName] else {
                throw OnnxRunnerError.missingOutput(metadata.encoderHiddenOutputName)
            }
            let encoderHiddenShape = try encoderHiddenOutput
                .tensorTypeAndShapeInfo().shape.map(\.intValue)
            guard encoderHiddenShape.count == 3,
                  encoderHiddenShape[0] == 1,
                  encoderHiddenShape[1] > 0,
                  encoderHiddenShape[2] > 0 else {
                throw OnnxRunnerError.invalidOutputShape(encoderHiddenShape)
            }
            let encoderTimeSteps = encoderHiddenShape[1]
            let encoderHiddenWidth = encoderHiddenShape[2]
            guard encoderHiddenWidth == metadata.expectedEncoderHiddenWidth else {
                throw OnnxRunnerError.encoderHiddenWidthMismatch(
                    expected: metadata.expectedEncoderHiddenWidth,
                    actual: encoderHiddenWidth
                )
            }
            guard encoderTimeSteps == timeSteps else {
                throw OnnxRunnerError.outputTimeStepMismatch(
                    logProbabilities: timeSteps,
                    encoderHidden: encoderTimeSteps
                )
            }
            let (encoderFloatCount, encoderCountOverflow) = encoderTimeSteps
                .multipliedReportingOverflow(by: encoderHiddenWidth)
            let (expectedEncoderByteCount, encoderByteOverflow) = encoderFloatCount
                .multipliedReportingOverflow(by: MemoryLayout<Float>.size)
            guard !encoderCountOverflow, !encoderByteOverflow else {
                throw OnnxRunnerError.invalidOutputShape(encoderHiddenShape)
            }
            let encoderData = try encoderHiddenOutput.tensorData() as Data
            guard encoderData.count == expectedEncoderByteCount else {
                throw OnnxRunnerError.outputByteCountMismatch(
                    expected: expectedEncoderByteCount,
                    actual: encoderData.count
                )
            }
            var encoderHiddenStates = [Float](
                repeating: 0,
                count: encoderFloatCount
            )
            encoderHiddenStates.withUnsafeMutableBytes { destination in
                _ = encoderData.copyBytes(to: destination)
            }
            guard encoderHiddenStates.allSatisfy(\.isFinite) else {
                throw OnnxRunnerError.inferenceFailed(
                    "encoder hidden output contains a non-finite value"
                )
            }

            return OnnxInferenceOutput(
                logProbabilities: logProbabilities,
                encoderHiddenStates: encoderHiddenStates,
                timeSteps: timeSteps,
                vocabularySize: vocabularySize,
                encoderHiddenWidth: encoderHiddenWidth
            )
        } catch let error as OnnxRunnerError {
            throw error
        } catch {
            throw OnnxRunnerError.inferenceFailed(error.localizedDescription)
        }
#else
        throw OnnxRunnerError.runtimeUnavailable
#endif
    }

    private static func sha256Hex(of url: URL) throws -> String {
        guard let stream = InputStream(url: url) else {
            throw OnnxRunnerError.modelReadFailed("could not open the file stream")
        }

        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)

        while true {
            let bytesRead = stream.read(&buffer, maxLength: buffer.count)
            if bytesRead < 0 {
                throw OnnxRunnerError.modelReadFailed(
                    stream.streamError?.localizedDescription ?? "unknown stream error"
                )
            }
            if bytesRead == 0 { break }
            hasher.update(data: Data(buffer[0..<bytesRead]))
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
