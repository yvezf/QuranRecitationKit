import Foundation
import QRKFFI

/// Read-only text and names for host UIs; Arabic is preserved from Tanzil.
/// Matching normalization is deliberately not exposed as display text.
public struct QuranCatalog: Sendable {
    public struct Surah: Decodable, Sendable, Identifiable {
        public let number: Int
        public let name: String
        public let arabicName: String
        public let ayahCount: Int
        public let bismillah: String
        public var id: Int { number }
        enum CodingKeys: String, CodingKey {
            case number, name = "name_en", arabicName = "name_ar", ayahCount = "ayah_count", bismillah
        }
    }
    public struct Ayah: Sendable, Identifiable {
        public let surah: Int
        public let number: Int
        public let arabic: String
        private let numberedArabic: String
        init(surah: Int, number: Int, arabic: String, numberedArabic: String) {
            self.surah = surah; self.number = number; self.arabic = arabic; self.numberedArabic = numberedArabic
        }
        public var id: String { "\(surah):\(number)" }
        public var words: [String] {
            var result: [String] = []
            for word in numberedArabic.split(whereSeparator: \.isWhitespace) {
                if !word.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }), !result.isEmpty {
                    result[result.count-1] += " " + word
                } else { result.append(String(word)) }
            }
            return result
        }
    }
    public let surahs: [Surah]
    public let attributionNotice: String
    private let text: [Int: [Ayah]]
    public init() throws {
        struct Source: Decodable { let surah: Int; let ayah: Int; let arabic: String }
        struct Attribution: Decodable { let notice: String }
        struct Document: Decodable { let surahs: [Surah]; let ayahs: [Source]; let attribution: Attribution }
        let json = try ownedString(qrk_corpus_json())
        let d = try JSONDecoder().decode(Document.self, from: Data(json.utf8))
        surahs = d.surahs; attributionNotice = d.attribution.notice
        // The source remains untouched. Slice unnumbered basmala for word highlighting only.
        struct Header: Decodable { let bismillah: String }
        struct Headers: Decodable { let surahs: [Header] }
        let headers = try JSONDecoder().decode(Headers.self, from: Data(json.utf8))
        func letters(_ text: String) -> String { String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            guard scalar.value != 0x0640 else { return false }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
            default: return false
            }
        })) }
        text = Dictionary(grouping: d.ayahs.map { source in
            var body = source.arabic
            let words = source.arabic.split(whereSeparator: \.isWhitespace)
            let header = headers.surahs[source.surah - 1].bismillah.split(whereSeparator: \.isWhitespace)
            if source.ayah == 1, source.surah != 1, source.surah != 9, words.count > 4, header.count == 4,
                zip(words.prefix(4), header).allSatisfy({ letters(String($0)) == letters(String($1)) }) {
                body = String(source.arabic[words[4].startIndex...])
            }
            return Ayah(surah: source.surah, number: source.ayah, arabic: source.arabic, numberedArabic: body)
        }, by: \.surah)
    }
    public func ayahs(in surah: Int) -> [Ayah] { text[surah] ?? [] }
}
