import XCTest
@testable import QuranRecitationKit
final class CrossLanguageParityTests: XCTestCase {
    private var fixtureDirectory: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("tests/fixtures")
    }
    func testSharedCTCFixtures() throws {
        struct Fixture: Decodable { let name: String; let time: Int; let vocab: Int; let blank: Int; let logits: [Float]; let target: [Int]; let score_per_frame: Double; let alignment: [[Int]] }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: fixtureDirectory.appendingPathComponent("scorer.json")))
        for f in fixtures {
            let scorer = CTCScorer(blankID: f.blank)
            let score = try scorer.score(logProbabilities: f.logits, timeSteps: f.time, vocabularySize: f.vocab, tokenIDs: f.target)
            XCTAssertEqual(score.logProbabilityPerFrame, f.score_per_frame, accuracy: 1e-4, f.name)
            if !f.target.isEmpty {
                let aligned = try scorer.forcedAlignment(logProbabilities: f.logits, timeSteps: f.time, vocabularySize: f.vocab, tokenIDs: f.target)
                XCTAssertEqual(aligned.tokenAlignments.map { [$0.emissionFrameRange.lowerBound,$0.emissionFrameRange.upperBound] }, f.alignment, f.name)
            }
            print("PARITY \(f.name) score=\(score.logProbabilityPerFrame)")
        }
    }
    func testSharedAlignerFixtures() throws {
        struct Fixture: Decodable { let expected:[String]; let decoded:String; let from:Int; let to:Int; let matches:[Int] }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: fixtureDirectory.appendingPathComponent("aligner.json")))
        for f in fixtures { XCTAssertEqual(ExpectedWordAligner.align(decodedText:f.decoded,expectedAyahWords:f.expected,lineWordRange:f.from..<f.to).matchedAyahWordIndices,Set(f.matches)) }
    }
    func testActualFatihaSixVariant() throws {
        let c = try QuranTokenCatalog.bundled()
        let line = try c.line(surahNumber:1,ayahNumber:6,ayahWordRange:0..<3)
        let alt = QuranPronunciationTokenVariants.auditedAlternateTokenization(expectedTokenIDs:line.tokenIDs,wordTokenEnds:line.wordTokenEnds,surahNumber:1,ayahNumber:6,ayahWordRange:0..<3)
        XCTAssertNotNil(alt)
        XCTAssertEqual(alt?.tokenIDs[5],112)
    }
}
