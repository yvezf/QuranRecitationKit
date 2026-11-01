import CryptoKit
import XCTest
@testable import QuranRecitationKit
@testable import QuranRecitationAudio

final class PackageTests: XCTestCase {
    func testCatalogCountsAndPreamble() throws {
        let catalog = try QuranTokenCatalog.bundled()
        let quran = try QuranCatalog()
        XCTAssertEqual(quran.surahs.count, 114)
        XCTAssertEqual(quran.surahs.reduce(0) { $0 + $1.ayahCount }, 6236)
        XCTAssertEqual(try catalog.normalizedAyahWords(surahNumber: 95, ayahNumber: 1), ["والتين", "والزيتون"])
        XCTAssertEqual(try catalog.normalizedAyahWords(surahNumber: 97, ayahNumber: 1), ["انا", "انزلنه", "في", "ليله", "القدر"])
        XCTAssertFalse(quran.ayahs(in: 97)[0].arabic.hasPrefix("بِسْمِ"))
        for s in quran.surahs {
            for a in quran.ayahs(in: s.number) {
                XCTAssertEqual(a.words.count, try catalog.normalizedAyahWords(surahNumber: s.number, ayahNumber: a.number).count, a.id)
            }
        }
    }
    func testCatalogRejectsTampering() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{}".utf8).write(to: url)
        XCTAssertThrowsError(try QuranTokenCatalog(resourceURL: url))
    }
    func testPartialWordTokenWindows() throws {
        let catalog = try QuranTokenCatalog.bundled()
        let all = try catalog.line(surahNumber: 1, ayahNumber: 7, ayahWordRange: 0..<9)
        let slice = try catalog.line(surahNumber: 1, ayahNumber: 7, ayahWordRange: 4..<9)
        XCTAssertEqual(slice.normalizedWords, Array(all.normalizedWords[4..<9]))
        XCTAssertEqual(slice.tokenIDs, Array(all.tokenIDs[all.wordTokenEnds[3]..<all.tokenIDs.count]))
        XCTAssertEqual(slice.wordTokenEnds.last, slice.tokenIDs.count)
        XCTAssertThrowsError(try catalog.line(surahNumber: 1, ayahNumber: 7, ayahWordRange: 8..<20))
    }
    func testCanonicalBoundedWindow() throws {
        let words = (0..<24).map { SurahCanonicalWordSource(normalizedText: "word\($0)", ayahNumber: $0 / 6 + 1, ayahWordIndex: $0 % 6, segmentIndex: $0 / 6) }
        let index = try CanonicalWordIndex(surahNumber: 112, wordSources: words)
        let window = try index.expectedWindow(aroundVerifiedCursor: 10,
            limits: SurahExpectedWindowLimits(backtrackWordCount: 2, maximumLookaheadWordCount: 5, maximumForwardSegmentCount: 2))
        XCTAssertEqual(window.globalWordRange, 8..<15)
        XCTAssertEqual(window.anchorLocalIndex, 2)
        XCTAssertEqual(try index.expectedWindow(aroundVerifiedCursor: 24).words.count, 0)
        XCTAssertThrowsError(try index.expectedWindow(aroundVerifiedCursor: 25))
    }
    func testModelPackRejectsCorruptPinnedModelAndManifestTraversal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest: [String: Any] = ["model": ["file": "fastconformer_full_mixed.onnx", "size": 88307457,
            "sha256": ModelMetadata.releaseV1.modelSHA256]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("model-manifest.json"))
        try Data("broken".utf8).write(to: dir.appendingPathComponent("fastconformer_full_mixed.onnx"))
        XCTAssertThrowsError(try ModelPack(directory: dir))
        let bytes = Data("synthetic".utf8)
        let metadata = ModelMetadata(modelFileName: "fake.onnx", modelByteCount: Int64(bytes.count),
            modelSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            audioInputName: "audio_signal", lengthInputName: "length", logProbabilitiesOutputName: "log_probs",
            encoderHiddenOutputName: "hidden", expectedVocabularySize: 1025, expectedEncoderHiddenWidth: 512,
            expectedSampleRate: 16000, maximumSampleCount: 192000)
        let fake = dir.appendingPathComponent("fake.onnx"); try bytes.write(to: fake)
        XCTAssertNoThrow(try OnnxRunner.validateModelFile(at: fake, metadata: metadata))
        try Data("Synthetic".utf8).write(to: fake)
        XCTAssertThrowsError(try OnnxRunner.validateModelFile(at: fake, metadata: metadata))
    }
    func testSyntheticIkhlasPublicEvents() async throws {
        let catalog = try QuranTokenCatalog.bundled()
        let tokens = try (1...4).flatMap { n -> [Int] in
            let words = try catalog.normalizedAyahWords(surahNumber: 112, ayahNumber: n)
            return try catalog.line(surahNumber: 112, ayahNumber: n, ayahWordRange: 0..<words.count).tokenIDs
        }
        let recognizer = try RecitationRecognizer(runner: StubRunner(output: synthetic(tokens)))
        try await recognizer.setExpected(.surah(112))
        await recognizer.feed([Float](repeating: 0.1, count: 64000))
        let summary = try await recognizer.stop()
        XCTAssertEqual(summary.verses.map(\.ayah), [1,2,3,4])
        var events: [RecitationEvent] = []
        for await event in recognizer.events {
            events.append(event)
            if event == .state(.ended) { break }
        }
        XCTAssertTrue(events.contains { if case .wordProgress = $0 { return true }; return false })
        XCTAssertEqual(events.filter { if case .verseMatch = $0 { return true }; return false }.count, 4)
        XCTAssertEqual(events.last, .state(.ended))
        await recognizer.reset()
    }
    func testSelectedWordRangeCompletesOnlyThatAyah() async throws {
        let c = try QuranTokenCatalog.bundled()
        let line = try c.line(surahNumber: 1, ayahNumber: 7, ayahWordRange: 4..<9)
        let r = try RecitationRecognizer(runner: StubRunner(output: synthetic(line.tokenIDs)))
        try await r.setExpected(.words(surah: 1, ayah: 7, range: 4..<9))
        await r.feed([Float](repeating: 0.1, count: 48000))
        let summary = try await r.stop()
        XCTAssertEqual(summary.verses.map(\.ayah), [7])
        XCTAssertEqual(summary.transcript, line.normalizedWords.joined(separator: " "))
    }
    func testLongAyahUsesBoundedOrderedSpans() async throws {
        let c = try QuranTokenCatalog.bundled()
        let words = try c.normalizedAyahWords(surahNumber: 2, ayahNumber: 255)
        let line = try c.line(surahNumber: 2, ayahNumber: 255, ayahWordRange: 0..<words.count)
        let r = try RecitationRecognizer(runner: StubRunner(output: synthetic(line.tokenIDs)))
        try await r.setExpected(.ayahs(surah: 2, range: 255...255))
        await r.feed([Float](repeating: 0.1, count: 128000))
        let result = try await r.stop()
        XCTAssertEqual(result.verses.map(\.ayah), [255])
    }
    func testPCMWindowRetainsExactBoundedTail() {
        var ring = PCMWindow(capacity: 4)
        ring.append(contentsOf: [1,2,3]); ring.append(contentsOf: [4,5,6])
        XCTAssertEqual(ring.samples,[3,4,5,6])
        ring.discardFirst(2); ring.append(contentsOf: [7]); XCTAssertEqual(ring.samples,[5,6,7])
    }
    func testResetFencesSlowInference() async throws {
        let c = try QuranTokenCatalog.bundled()
        let tokens = try c.line(surahNumber: 112, ayahNumber: 1, ayahWordRange: 0..<4).tokenIDs
        let r = try RecitationRecognizer(runner: DelayedRunner(output: synthetic(tokens)))
        try await r.setExpected(.ayahs(surah: 112, range: 1...1))
        await r.feed([Float](repeating: 0.1, count: 32000))
        await Task.yield(); await r.reset()
        let summary = try await r.stop()
        XCTAssertTrue(summary.verses.isEmpty)
    }
    func testNoiseAndTooShortNeverComplete() async throws {
        let r = try RecitationRecognizer(runner: StubRunner(output: synthetic([])))
        try await r.setExpected(.surah(112))
        await r.feed([Float](repeating: 0, count: 100))
        let result = try await r.stop()
        XCTAssertTrue(result.verses.isEmpty)
        var reasons: [RetryReason] = []
        for await event in r.events {
            if case .needsRetry(let reason) = event { reasons.append(reason) }
            if event == .state(.ended) { break }
        }
        XCTAssertEqual(reasons, [.tooShort])
    }
    func testWrongSurahIsNotAccepted() async throws {
        let c = try QuranTokenCatalog.bundled()
        let words = try c.normalizedAyahWords(surahNumber: 1, ayahNumber: 1)
        let t = try c.line(surahNumber: 1, ayahNumber: 1, ayahWordRange: 0..<words.count).tokenIDs
        let r = try RecitationRecognizer(runner: StubRunner(output: synthetic(t)))
        try await r.setExpected(.surah(112)); await r.feed([Float](repeating: 0.1, count: 32000))
        let result = try await r.stop(); XCTAssertTrue(result.verses.isEmpty)
    }
    func testInvalidTargetDoesNotDestroyValidTarget() async throws {
        let r = try RecitationRecognizer(runner: StubRunner(output: synthetic([])))
        try await r.setExpected(.surah(112))
        do { try await r.setExpected(.words(surah: 112, ayah: 1, range: 0..<100)); XCTFail("invalid range accepted") } catch {}
        await r.reset()
    }
    func testResamplingHasNoChunkBoundaryDiscontinuities() {
        let input = (0..<4410).map { Float(sin(Double($0) / 20)) }
        var a = AudioResampler(inputSampleRate: 44100)
        var b = AudioResampler(inputSampleRate: 44100)
        let whole = a.process(input)
        var split: [Float] = []
        for i in stride(from: 0, to: input.count, by: 93) { split += b.process(Array(input[i..<min(i+93,input.count)])) }
        XCTAssertEqual(whole.count, split.count)
        XCTAssertLessThan(zip(whole,split).map { abs($0-$1) }.max()!, 0.0001)
    }
    func testPolicyPresetsPreserveIdentityAndChangeEndpointPacing() async throws {
        let catalog = try QuranTokenCatalog.bundled()
        let tokens = try catalog.line(surahNumber: 112, ayahNumber: 1, ayahWordRange: 0..<4).tokenIDs
        for configuration in [RecitationConfiguration.balanced, .conservative, .lenient] {
            let r = try RecitationRecognizer(runner: StubRunner(output: synthetic(tokens)), configuration: configuration)
            try await r.setExpected(.ayahs(surah: 112, range: 1...1))
            await r.feed([Float](repeating: 0.1, count: 32000))
            let summary = try await r.stop()
            XCTAssertEqual(summary.verses.map(\.ayah), [1])
        }
    }
    func testModelDownloadRejectsUnconfiguredOrIncompatibleSourceWithoutNetwork() async throws {
        do { _ = try await ModelPack.download(); XCTFail("Unconfigured source accepted") }
        catch ModelPackError.repositoryNotConfigured {} catch { XCTFail("Unexpected error: \(error)") }
        let source = ModelSource(url: URL(string: "http://localhost/model")!, sha256: "bad", byteCount: 1)
        do { _ = try await ModelPack.download(from: source); XCTFail("Invalid source accepted") }
        catch ModelPackError.incompatibleManifest {} catch { XCTFail("Unexpected error: \(error)") }
    }
    func testEndpointFeatureParity() throws { try EndpointHeadFeatureParityFixture.verify() }
    func testONNXIntegrationOnlyWhenOptedIn() async throws {
        guard let path = ProcessInfo.processInfo.environment["QRK_MODEL_DIR"] else {
            throw XCTSkip("Set QRK_MODEL_DIR to an already-local release model; no model is downloaded by tests.")
        }
        let pack = try ModelPack(directory: URL(fileURLWithPath: path))
        let runner = OnnxRunner(modelURL: pack.modelURL)
        let output = try await runner.run(monoPCM16kHz: (0..<32000).map { Float(sin(Double($0)*0.0864)*0.02) })
        XCTAssertEqual(output.vocabularySize, 1025); XCTAssertEqual(output.encoderHiddenWidth, 512)
        XCTAssertEqual(output.logProbabilities.count, output.timeSteps * 1025)
        XCTAssertEqual(output.encoderHiddenStates.count, output.timeSteps * 512)
        XCTAssertTrue(output.logProbabilities.allSatisfy(\.isFinite))
        XCTAssertTrue(output.encoderHiddenStates.allSatisfy(\.isFinite))
    }
}
struct StubRunner: AcousticModelRunning {
    let output: OnnxInferenceOutput
    func run(monoPCM16kHz audio: [Float]) async throws -> OnnxInferenceOutput { output }
    func cancelPendingInference() {}
}
func synthetic(_ tokens: [Int]) -> OnnxInferenceOutput {
    var frames = [1024]
    for token in tokens { frames += [token,token,1024] }
    frames += [1024,1024,1024]
    var logits = [Float](repeating: -12, count: frames.count * 1025)
    for (i,t) in frames.enumerated() { logits[i*1025+t] = -0.001 }
    return OnnxInferenceOutput(logProbabilities: logits, encoderHiddenStates: [], timeSteps: frames.count, vocabularySize: 1025, encoderHiddenWidth: 512)
}

struct DelayedRunner: AcousticModelRunning {
    let output: OnnxInferenceOutput
    func run(monoPCM16kHz audio: [Float]) async throws -> OnnxInferenceOutput {
        try await Task.sleep(nanoseconds: 20_000_000)
        return output
    }
    func cancelPendingInference() {}
}
