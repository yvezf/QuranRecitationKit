import Foundation
import QRKFFI

public struct RecognitionError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}
func checked(_ status: Int32) throws {
    guard status == 0 else { throw RecognitionError(message: String(cString: qrk_last_error())) }
}
func ownedString(_ pointer: UnsafeMutablePointer<CChar>?) throws -> String {
    guard let pointer else { throw RecognitionError(message: "Native engine returned no data.") }
    defer { qrk_string_free(pointer) }; return String(cString: pointer)
}
struct WireEvent: Decodable {
    let type: String
    let surah: Int?; let ayah: Int?; let confidence: Double?
    let word_index: Int?; let total_words: Int?; let matched_word_indices: [Int]?
    let duration_seconds: Double?; let reason: String?; let text: String?; let state: String?
    func event() throws -> RecitationEvent {
        switch type {
        case "word_progress":
            guard let surah, let ayah, let word_index, let total_words, let matched_word_indices, let confidence else { throw invalid }
            return .wordProgress(.init(surah: surah, ayah: ayah, wordIndex: word_index, totalWords: total_words, matchedWordIndices: Set(matched_word_indices), confidence: confidence))
        case "verse_match": return .verseMatch(try verse())
        case "needs_retry":
            let value: RetryReason?
            switch reason { case "off_target": value = .offTarget; case "too_short": value = .tooShort
            default: value = reason.flatMap(RetryReason.init(rawValue:)) }
            guard let value else { throw invalid }; return .needsRetry(value)
        case "raw_transcript":
            guard let text, let confidence else { throw invalid }; return .rawTranscript(.init(text: text, confidence: confidence))
        case "state":
            guard let value = state.flatMap(RecognitionState.init(rawValue:)) else { throw invalid }; return .state(value)
        default: throw invalid
        }
    }
    func verse() throws -> VerseMatch {
        guard let surah, let ayah, let confidence, let duration_seconds else { throw invalid }
        return .init(surah: surah, ayah: ayah, confidence: confidence, durationSeconds: duration_seconds)
    }
    private var invalid: RecognitionError { .init(message: "Invalid native event: \(type)") }
}
final class EventBridge: @unchecked Sendable {
    let continuation: AsyncStream<RecitationEvent>.Continuation
    private let lock = NSLock()
    private var failure: RecognitionError?
    init(_ continuation: AsyncStream<RecitationEvent>.Continuation) { self.continuation = continuation }
    func accept(_ json: String) {
        do { continuation.yield(try JSONDecoder().decode(WireEvent.self, from: Data(json.utf8)).event()) }
        catch { lock.lock(); failure = RecognitionError(message: error.localizedDescription); lock.unlock() }
    }
    func takeFailure() -> RecognitionError? { lock.lock(); defer { lock.unlock() }; let result = failure; failure = nil; return result }
}
final class NativeHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { qrk_free(pointer) }
}
