import XCTest
@testable import QuranRecitationKit

final class SpotTests: XCTestCase {
    func testModelFreeMatchIsUnverifiedAndAmbiguous() async throws {
        let result=try await RecitationSpotter.matchText("الذين آمنوا")
        XCTAssertFalse(result.verified);XCTAssertTrue(result.ambiguous);XCTAssertGreaterThanOrEqual(result.candidates.count,2)
        XCTAssertTrue(result.candidates.allSatisfy{$0.confidence<=0.5})
        let english=try await RecitationSpotter.matchText("The teacher explains the timetable")
        XCTAssertTrue(english.candidates.isEmpty)
    }
    func testAmbiguousQuoteHasNoSelectedVerse() throws {
        let payload="""
        {"type":"quote_detected","surah":null,"ayah_from":null,"ayah_to":null,"word_from":null,"word_to":null,"start_seconds":2,"end_seconds":4,"confidence":0.5,"text_uthmani":null,"reference":null,"verified":false,"ambiguous":true,"candidates":[{"surah":1,"ayah_from":1,"ayah_to":1,"word_from":0,"word_to":4,"confidence":0.5,"text_uthmani":"sample","reference":"Al-Fatiha 1:1"},{"surah":27,"ayah_from":30,"ayah_to":30,"word_from":4,"word_to":8,"confidence":0.5,"text_uthmani":"sample","reference":"An-Naml 27:30"}]}
        """
        let wire=try JSONDecoder().decode(WireEvent.self,from:Data(payload.utf8))
        guard case .quoteDetected(let quote)=try wire.spotEvent() else{return XCTFail("missing quote")}
        XCTAssertFalse(quote.verified);XCTAssertNil(quote.surah);XCTAssertNil(quote.textUthmani);XCTAssertEqual(quote.candidates.count,2)
    }
}
