import CryptoKit
import Foundation

public struct ModelSource: Sendable {
    /// Set this once when publishing the model release. No repository is created by this package.
    public static let repositoryOwner = "<OWNER>"
    public let url: URL
    public let sha256: String
    public let byteCount: Int64
    public init(url: URL, sha256: String, byteCount: Int64) {
        self.url = url; self.sha256 = sha256; self.byteCount = byteCount
    }
    public static let `default` = Self(
        url: URL(string: "https://github.com/\(repositoryOwner)/QuranRecitationKit/releases/download/model-v1/fastconformer_full_mixed.onnx")!,
        sha256: ModelMetadata.releaseV1.modelSHA256, byteCount: ModelMetadata.releaseV1.modelByteCount)
}

public struct ModelPack: Sendable {
    public let modelURL: URL
    public init(directory: URL) throws {
        let data = try Data(contentsOf: directory.appendingPathComponent("model-manifest.json"))
        let manifest = try JSONDecoder().decode(PackManifest.self, from: data)
        let expected = ModelMetadata.releaseV1
        guard manifest.model.file == expected.modelFileName,
              manifest.model.size == expected.modelByteCount,
              manifest.model.sha256.lowercased() == expected.modelSHA256 else {
            throw ModelPackError.incompatibleManifest
        }
        let url = directory.appendingPathComponent(expected.modelFileName)
        try OnnxRunner.validateModelFile(at: url)
        modelURL = url
    }
    public static func download(from source: ModelSource = .default, to cache: URL? = nil,
                                progress: (@Sendable (Double) -> Void)? = nil) async throws -> ModelPack {
        let expected = ModelMetadata.releaseV1
        if source.url == ModelSource.default.url && ModelSource.repositoryOwner.hasPrefix("<") { throw ModelPackError.repositoryNotConfigured }
        guard source.sha256 == expected.modelSHA256, source.byteCount == expected.modelByteCount,
              source.url.scheme == "https" else { throw ModelPackError.incompatibleManifest }
        let directory = try cache ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("QuranRecitationKit/model-v1", isDirectory: true)
        if let cached = try? ModelPack(directory: directory) { progress?(1); return cached }
        return try await ModelDownloader.shared.download(source: source, directory: directory, progress: progress)
    }
}
public enum ModelPackError: Error, LocalizedError {
    case incompatibleManifest, httpStatus(Int), invalidDownload, repositoryNotConfigured
    public var errorDescription: String? {
        switch self {
        case .repositoryNotConfigured: return "Set ModelSource.repositoryOwner after publishing the model release, or load a local ModelPack(directory:)."
        case .incompatibleManifest: return "The model manifest does not match this release."
        case .httpStatus(let status): return "Model download returned HTTP \(status)."
        case .invalidDownload: return "The downloaded model failed integrity verification."
        }
    }
}
private struct PackManifest: Decodable {
    struct Model: Decodable { let file: String; let size: Int64; let sha256: String }
    let model: Model
}

/// Serializes cache installation; incomplete files never become a usable model pack.
private actor ModelDownloader {
    static let shared = ModelDownloader()
    private final class Flight {
        let id = UUID()
        let task: Task<ModelPack, Error>
        var ledger = SharedTaskLeaseLedger()
        let generation: UInt64
        let observers: ProgressObservers
        init(task: Task<ModelPack, Error>, observers: ProgressObservers) {
            self.task = task; self.observers = observers
            generation = ledger.beginGeneration()
        }
    }
    private var active: [URL: Flight] = [:]
    func download(source: ModelSource, directory: URL, progress: (@Sendable (Double) -> Void)?) async throws -> ModelPack {
        let flight: Flight
        if let existing = active[directory] { flight = existing }
        else {
        let observers = ProgressObservers()
        let delegate = DownloadProgress { observers.emit($0) }
        let task = Task<ModelPack, Error> {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            observers.emit(0)
            let (temporary, response) = try await session.download(from: source.url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw ModelPackError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            try Task.checkCancellation()
            // Validate in a sibling staging directory, then atomically rename each file on the same volume.
            let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let model = staging.appendingPathComponent(ModelMetadata.releaseV1.modelFileName)
            try FileManager.default.moveItem(at: temporary, to: model)
            try OnnxRunner.validateModelFile(at: model)
            let manifest = Bundle.module.url(forResource: "model-manifest", withExtension: "json")!
            try FileManager.default.copyItem(at: manifest, to: staging.appendingPathComponent("model-manifest.json"))
            _ = try ModelPack(directory: staging)
            try Task.checkCancellation()
            for name in [ModelMetadata.releaseV1.modelFileName, "model-manifest.json"] {
                let target = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: target.path) {
                    _ = try FileManager.default.replaceItemAt(target, withItemAt: staging.appendingPathComponent(name))
                } else { try FileManager.default.moveItem(at: staging.appendingPathComponent(name), to: target) }
            }
            observers.emit(1)
            return try ModelPack(directory: directory)
        }
        flight = Flight(task: task, observers: observers)
        active[directory] = flight
        }
        let lease = flight.ledger.acquire(generation: flight.generation)
        let observer = flight.observers.add(progress)
        defer {
            flight.observers.remove(observer)
            release(directory, flightID: flight.id, lease: lease, cancelled: false)
        }
        return try await withTaskCancellationHandler(operation: {
            let pack = try await flight.task.value
            try Task.checkCancellation()
            return pack
        }, onCancel: { [self, id = flight.id] in
            Task { await self.release(directory, flightID: id, lease: lease, cancelled: true) }
        })
    }
    private func release(_ directory: URL, flightID: UUID, lease: SharedTaskWaiterLease, cancelled: Bool) {
        guard let flight = active[directory], flight.id == flightID else { return }
        let result = flight.ledger.release(lease)
        if result.shouldCancelCurrentTask && cancelled { flight.task.cancel() }
        if result.remainingWaiterCount == 0 { active[directory] = nil }
    }
}
private final class ProgressObservers: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [UUID: @Sendable (Double) -> Void] = [:]
    private var latest = 0.0
    func add(_ callback: (@Sendable (Double) -> Void)?) -> UUID {
        let id = UUID(); lock.lock(); callbacks[id] = callback; let value = latest; lock.unlock()
        callback?(value); return id
    }
    func remove(_ id: UUID) { lock.lock(); callbacks[id] = nil; lock.unlock() }
    func emit(_ value: Double) {
        lock.lock(); latest = value; let observers = Array(callbacks.values); lock.unlock()
        observers.forEach { $0(value) }
    }
}
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let callback: (@Sendable (Double) -> Void)?
    init(_ callback: (@Sendable (Double) -> Void)?) { self.callback = callback }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        callback?(min(0.99, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }
}
