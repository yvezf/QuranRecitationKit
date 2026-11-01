import Foundation

/// Read-only text and names for host UIs; Arabic is preserved from Tanzil.
/// Matching normalization is deliberately not exposed as display text.
public struct QuranCatalog: Sendable {
    public struct Surah: Decodable, Sendable, Identifiable {
        public let number: Int
        public let name: String
        public let arabicName: String
        public let ayahCount: Int
        public var id: Int { number }
        enum CodingKeys: String, CodingKey {
            case number, name = "name_en", arabicName = "name_ar", ayahCount = "ayah_count"
        }
    }
    public struct Ayah: Sendable, Identifiable {
        public let surah: Int
        public let number: Int
        public let arabic: String
        public var id: String { "\(surah):\(number)" }
        public var words: [String] {
            var result: [String] = []
            for word in arabic.split(whereSeparator: \.isWhitespace) {
                if !word.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }), !result.isEmpty {
                    result[result.count-1] += " " + word
                } else { result.append(String(word)) }
            }
            return result
        }
    }
    public let surahs: [Surah]
    private let text: [Int: [Ayah]]
    public init() throws {
        struct Document: Decodable {
            let surahs: [Surah]; let arabic: [String]
        }
        let data = try Data(contentsOf: Bundle.module.url(forResource: "quran-token-map", withExtension: "json")!)
        let d = try JSONDecoder().decode(Document.self, from: data)
        var cursor = 0; var result: [Int: [Ayah]] = [:]
        for surah in d.surahs {
            result[surah.number] = (1...surah.ayahCount).map { number in
                defer { cursor += 1 }
                return Ayah(surah: surah.number, number: number, arabic: d.arabic[cursor])
            }
        }
        surahs = d.surahs; text = result
    }
    public func ayahs(in surah: Int) -> [Ayah] { text[surah] ?? [] }
}
