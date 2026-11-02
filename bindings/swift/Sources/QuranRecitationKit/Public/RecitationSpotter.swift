import Foundation
import QRKFFI

public struct SpotConfiguration: Sendable {
    public var windowSeconds: Double
    public var minimumWords: Int
    public var minimumSeconds: Double
    public var minimumMargin: Double
    public var highMargin: Double
    public var ambiguityMargin: Double
    public var maximumCandidates: Int
    public init(windowSeconds: Double = 8, minimumWords: Int = 3, minimumSeconds: Double = 1.5, minimumMargin: Double = 0.035, highMargin: Double = 0.20, ambiguityMargin: Double = 0.05, maximumCandidates: Int = 8) {
        self.windowSeconds=windowSeconds; self.minimumWords=minimumWords;self.minimumSeconds=minimumSeconds;self.minimumMargin=minimumMargin;self.highMargin=highMargin;self.ambiguityMargin=ambiguityMargin;self.maximumCandidates=maximumCandidates
    }
}
public struct QuoteCandidate: Codable, Sendable, Equatable {
    public let surah: Int
    public let ayahFrom: Int
    public let ayahTo: Int
    /// Zero-based, half-open offsets within the first/last ayah.
    public let wordFrom: Int
    public let wordTo: Int
    public let confidence: Double
    public let textUthmani: String
    public let reference: String
    enum CodingKeys: String, CodingKey { case surah, confidence, reference; case ayahFrom="ayah_from",ayahTo="ayah_to",wordFrom="word_from",wordTo="word_to",textUthmani="text_uthmani" }
}
public struct QuoteDetected: Codable, Sendable, Equatable {
    /// Nil when ambiguous: there is no selected citation to insert.
    public let surah: Int?
    public let ayahFrom: Int?
    public let ayahTo: Int?
    public let wordFrom: Int?
    public let wordTo: Int?
    public let startSeconds: Double
    public let endSeconds: Double
    public let confidence: Double
    public let textUthmani: String?
    public let reference: String?
    public let verified: Bool
    public let ambiguous: Bool
    public let candidates: [QuoteCandidate]
    enum CodingKeys: String, CodingKey { case surah,confidence,reference,verified,ambiguous,candidates;case ayahFrom="ayah_from",ayahTo="ayah_to",wordFrom="word_from",wordTo="word_to",startSeconds="start_seconds",endSeconds="end_seconds",textUthmani="text_uthmani" }
}
public struct TextMatch: Codable, Sendable, Equatable {
    public let verified: Bool
    public let ambiguous: Bool
    public let candidates: [QuoteCandidate]
}
public struct SpotSummary: Sendable {
    public let quotes: [QuoteDetected]
    public let duration: Double
}
/// Independent, mono 16 kHz quotation session. Does not transcribe a lecture.
public actor RecitationSpotter {
    public nonisolated let events: AsyncStream<SpotEvent>
    private let handle: SpotHandle
    private let bridge: SpotEventBridge
    public init(modelPack: ModelPack, configuration: SpotConfiguration = .init()) async throws {
        let config: [String:Any] = ["window_seconds":configuration.windowSeconds,"min_words":configuration.minimumWords,"min_seconds":configuration.minimumSeconds,"min_margin":configuration.minimumMargin,"high_margin":configuration.highMargin,"ambiguity_margin":configuration.ambiguityMargin,"max_candidates":configuration.maximumCandidates]
        let json=String(decoding:try JSONSerialization.data(withJSONObject:config),as:UTF8.self)
        var pointer: OpaquePointer?
        try checked(qrk_spotter_new(modelPack.modelURL.deletingLastPathComponent().path,nil,json,&pointer))
        guard let pointer else {throw RecognitionError(message:"Native spotter was not created.")}
        handle=SpotHandle(pointer)
        let stream=AsyncStream<SpotEvent>.makeStream(bufferingPolicy:.bufferingNewest(512));events=stream.stream;bridge=SpotEventBridge(stream.continuation)
    }
    deinit {bridge.continuation.finish()}
    public func feed(_ pcm16k:[Float]) async throws {
        try pcm16k.withUnsafeBufferPointer { samples in
            try checked(qrk_spotter_feed(handle.pointer,samples.baseAddress,UInt(samples.count),{ json,context in
                guard let json,let context else{return};Unmanaged<SpotEventBridge>.fromOpaque(context).takeUnretainedValue().accept(String(cString:json))
            },Unmanaged.passUnretained(bridge).toOpaque()))
        }
        if let error=bridge.takeFailure(){throw error}
    }
    public func stop() async throws -> SpotSummary {
        var pointer:UnsafeMutablePointer<CChar>?
        try checked(qrk_spotter_stop(handle.pointer,&pointer));let json=try ownedString(pointer)
        struct Wire:Decodable {let quotes:[QuoteDetected];let duration:Double;let events:[WireEvent]}
        let result=try JSONDecoder().decode(Wire.self,from:Data(json.utf8))
        for event in result.events {bridge.continuation.yield(try event.spotEvent())}
        return .init(quotes:result.quotes,duration:result.duration)
    }
    public func reset() async throws {try checked(qrk_spotter_reset(handle.pointer));bridge.continuation.yield(.state(.idle))}
    /// Model-free candidates. No acoustic model download or account is required.
    public nonisolated static func matchText(_ text:String) async throws -> TextMatch {
        try await Task.detached {
            var pointer:UnsafeMutablePointer<CChar>?
            try checked(qrk_match_text(text,&pointer))
            return try JSONDecoder().decode(TextMatch.self,from:Data(ownedString(pointer).utf8))
        }.value
    }
}
private final class SpotHandle: @unchecked Sendable {
    let pointer:OpaquePointer
    init(_ pointer:OpaquePointer){self.pointer=pointer}
    deinit {qrk_spotter_free(pointer)}
}
public typealias Spotter = RecitationSpotter

/// Separate from tracking events, so existing tracking switches stay source-compatible.
public enum SpotEvent: Sendable, Equatable {
    case quoteDetected(QuoteDetected)
    case state(RecognitionState)
}
private final class SpotEventBridge: @unchecked Sendable {
    let continuation: AsyncStream<SpotEvent>.Continuation
    private let lock=NSLock()
    private var failure:RecognitionError?
    init(_ continuation:AsyncStream<SpotEvent>.Continuation){self.continuation=continuation}
    func accept(_ json:String){
        do{continuation.yield(try JSONDecoder().decode(WireEvent.self,from:Data(json.utf8)).spotEvent())}
        catch{lock.lock();failure=RecognitionError(message:error.localizedDescription);lock.unlock()}
    }
    func takeFailure()->RecognitionError?{lock.lock();defer{lock.unlock()};let value=failure;failure=nil;return value}
}
