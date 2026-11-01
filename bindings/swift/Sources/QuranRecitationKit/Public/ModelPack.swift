import CryptoKit
import Foundation
import QRKFFI

private struct ModelInfo: Decodable {
    let url: String; let configured: Bool; let sha256: String; let byte_count: Int64
    let cache_directory: String?
    static let payload: Data = Data(try! ownedString(qrk_model_source_json()).utf8)
    static let manifest: Data = {
        let object = try! JSONSerialization.jsonObject(with: payload) as! [String: Any]
        return try! JSONSerialization.data(withJSONObject: object["manifest"]!, options: [.sortedKeys])
    }()
    static let current: Self = {
        // This is engine-compiled metadata, not an external or user-controlled file.
        return try! JSONDecoder().decode(Self.self, from: payload)
    }()
}
public struct ModelSource: Sendable {
    public let url: URL; public let sha256: String; public let byteCount: Int64
    public init(url: URL, sha256: String, byteCount: Int64) { self.url = url; self.sha256 = sha256; self.byteCount = byteCount }
    /// The single release-owner setting lives in the Rust core, shared by every binding.
    public static let `default` = Self(url: URL(string: ModelInfo.current.url)!, sha256: ModelInfo.current.sha256, byteCount: ModelInfo.current.byte_count)
}
public struct ModelPack: Sendable {
    public let modelURL: URL
    public init(directory: URL) throws {
        struct Manifest: Decodable { struct Model: Decodable { let file: String; let size: Int64; let sha256: String }; let model: Model }
        let m = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("model-manifest.json"))).model
        guard m.file == "fastconformer_full_mixed.onnx", m.size == ModelInfo.current.byte_count, m.sha256 == ModelInfo.current.sha256 else { throw ModelPackError.incompatibleManifest }
        let file = directory.appendingPathComponent(m.file)
        try Self.validate(file); modelURL = file
    }
    static func validate(_ file: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == ModelInfo.current.byte_count,
              attributes[.type] as? FileAttributeType == .typeRegular else { throw ModelPackError.invalidDownload }
        let f = try FileHandle(forReadingFrom: file); defer { try? f.close() }
        var hash = SHA256()
        while let data = try f.read(upToCount: 65_536), !data.isEmpty { hash.update(data: data) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == ModelInfo.current.sha256 else { throw ModelPackError.invalidDownload }
    }
    public static func download(from source: ModelSource = .default, to cache: URL? = nil,
        progress: (@Sendable (Double) -> Void)? = nil) async throws -> ModelPack {
        guard source.sha256 == ModelInfo.current.sha256, source.byteCount == ModelInfo.current.byte_count, source.url.scheme == "https" else { throw ModelPackError.incompatibleManifest }
        if source.url == ModelSource.default.url && !ModelInfo.current.configured { throw ModelPackError.repositoryNotConfigured }
        let defaultRoot: URL
        if let directory = ModelInfo.current.cache_directory {
            defaultRoot = URL(fileURLWithPath: directory, isDirectory: true)
        } else {
            // Compatibility with older native archives: derive their tag from their URL.
            let release = URL(string: ModelInfo.current.url)!.deletingLastPathComponent().lastPathComponent
            defaultRoot = URL(fileURLWithPath: try ownedString(qrk_cache_directory()), isDirectory: true).appendingPathComponent(release)
        }
        let root = cache ?? defaultRoot
        return try await ModelDownloads.shared.load(source, root, progress)
    }
}
public enum ModelPackError: Error, LocalizedError {
    case incompatibleManifest, httpStatus(Int), invalidDownload, repositoryNotConfigured
    public var errorDescription: String? {
        switch self {
        case .incompatibleManifest: return "The model does not match the pinned release."
        case .httpStatus(let s): return "Model download returned HTTP \(s)."
        case .invalidDownload: return "Model integrity verification failed."
        case .repositoryNotConfigured: return "The model release is not published yet. Supply a local ModelPack(directory:) or an HTTPS mirror of the pinned model."
        }
    }
}
private actor ModelDownloads {
    static let shared = ModelDownloads()
    // Shared downloads finish for remaining callers even if one caller is cancelled.
    private var flights: [URL: Task<ModelPack, Error>] = [:]
    func load(_ source: ModelSource, _ directory: URL, _ progress: (@Sendable (Double) -> Void)?) async throws -> ModelPack {
        if let cached = try? ModelPack(directory: directory) { progress?(1); return cached }
        if let flight = flights[directory] { let value = try await flight.value; try Task.checkCancellation(); progress?(1); return value }
        let task = Task.detached { () throws -> ModelPack in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let delegate = DownloadProgress(source.byteCount, progress)
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            progress?(0)
            let (file, response) = try await session.download(from: source.url)
            defer { try? FileManager.default.removeItem(at: file) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ModelPackError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1) }
            try ModelPack.validate(file)
            let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.moveItem(at: file, to: staging.appendingPathComponent("fastconformer_full_mixed.onnx"))
            try ModelInfo.manifest.write(to: staging.appendingPathComponent("model-manifest.json"), options: .atomic)
            _ = try ModelPack(directory: staging)
            for name in ["fastconformer_full_mixed.onnx", "model-manifest.json"] {
                let dest = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: dest.path) { _ = try FileManager.default.replaceItemAt(dest, withItemAt: staging.appendingPathComponent(name)) }
                else { try FileManager.default.moveItem(at: staging.appendingPathComponent(name), to: dest) }
            }
            progress?(1); return try ModelPack(directory: directory)
        }
        flights[directory] = task
        defer { flights[directory] = nil }
        let value = try await task.value; try Task.checkCancellation(); return value
    }
}
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let maximum: Int64; let callback: (@Sendable (Double) -> Void)?
    init(_ maximum: Int64, _ callback: (@Sendable (Double) -> Void)?) { self.maximum = maximum; self.callback = callback }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximum { downloadTask.cancel(); return }
        callback?(min(0.99, Double(totalBytesWritten) / Double(maximum)))
    }
}
