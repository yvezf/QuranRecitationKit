import XCTest
import QuranRecitationAudio
@testable import QuranRecitationKit
final class BindingTests: XCTestCase {
    func testCatalogAndIntegrityGuard() throws {
        let c = try QuranCatalog()
        XCTAssertEqual(c.surahs.count, 114)
        XCTAssertEqual(c.surahs.reduce(0) { $0 + $1.ayahCount }, 6236)
        XCTAssertFalse(c.ayahs(in: 97)[0].arabic.isEmpty)
        XCTAssertEqual(c.ayahs(in: 97)[0].words.count, 5)
        XCTAssertEqual(c.ayahs(in: 95)[0].words.count, 2)
        XCTAssertThrowsError(try ModelPack(directory: URL(fileURLWithPath: "/missing-model")))
    }
    func testNoResamplingChangesNoSamples() {
        var r = AudioResampler(inputSampleRate: 16000)
        XCTAssertEqual(r.process([0.1, -0.25, 0.3]), [0.1, -0.25, 0.3])
        XCTAssertEqual(r.process([0.8]), [0.8])
    }
    func testWireEvents() throws {
        let data = Data(#"{"type":"needs_retry","reason":"off_target"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(WireEvent.self, from: data).event(), .needsRetry(.offTarget))
        XCTAssertThrowsError(try JSONDecoder().decode(WireEvent.self, from: Data(#"{"type":"verse_match"}"#.utf8)).event())
    }
    func testSilenceThroughNative() async throws {
        guard let path = ProcessInfo.processInfo.environment["QRK_MODEL_DIR"] else { throw XCTSkip("Set QRK_MODEL_DIR for native model smoke") }
        let r = try await RecitationRecognizer(modelPack: ModelPack(directory: URL(fileURLWithPath: path)))
        try await r.setExpected(.surah(112)); await r.feed([Float](repeating: 0, count: 16_000))
        let summary = try await r.stop(); XCTAssertTrue(summary.verses.isEmpty)
        XCTAssertEqual(summary.duration, 1, accuracy: 0.01)
        await r.reset()
    }
    func testOwnerPCMParityWhenSupplied() async throws {
        guard let path = ProcessInfo.processInfo.environment["QRK_TEST_PCM16"],
              let model = ProcessInfo.processInfo.environment["QRK_MODEL_DIR"] else { throw XCTSkip("Set local PCM/model paths for owner-clip parity") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let pcm: [Float] = stride(from: 0, to: data.count - 1, by: 2).map { i in
            Float(Int16(bitPattern: UInt16(data[i]) | UInt16(data[i + 1]) << 8)) / 32768
        }
        let r = try await RecitationRecognizer(modelPack: ModelPack(directory: URL(fileURLWithPath: model)))
        try await r.setExpected(.ayahs(surah: 78, range: 1...1))
        for start in stride(from: 0, to: pcm.count, by: 4800) { await r.feed(Array(pcm[start..<min(start + 4800, pcm.count)])) }
        let summary = try await r.stop()
        XCTAssertEqual(summary.verses.count, 1)
        if let v = summary.verses.first { print("BINDING_PARITY \(v.surah):\(v.ayah) confidence=\(v.confidence) duration=\(v.durationSeconds) transcript=\(summary.transcript)") }
    }

}
