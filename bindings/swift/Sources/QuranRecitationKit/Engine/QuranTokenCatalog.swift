import CryptoKit
import Foundation

struct QuranTokenLine: Equatable, Sendable {
    let surahNumber: Int
    let ayahNumber: Int
    let ayahWordRange: Range<Int>
    let normalizedWords: [String]
    let tokenIDs: [Int]
    /// Cumulative exclusive token ends for this line's semantic words. Values
    /// are line-local, strictly increasing, and end at `tokenIDs.count`.
    let wordTokenEnds: [Int]
}

enum QuranTokenCatalogError: Error, Equatable, Sendable {
    case missingResource(String)
    case unreadableResource(String)
    case resourceSizeMismatch(expected: Int, actual: Int)
    case resourceHashMismatch(expected: String, actual: String)
    case invalidSchemaVersion(Int)
    case invalidRecordLayout
    case invalidAyahCount(Int)
    case invalidAyah(surah: Int, ayah: Int, reason: String)
    case duplicateAyah(surah: Int, ayah: Int)
    case missingAyah(surah: Int, ayah: Int)
    case lineRangeMismatch(surah: Int, ayah: Int, range: Range<Int>)
    case invalidConfuserPolicy(String)
    case invalidConfuserLayout(String)
}

extension QuranTokenCatalogError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .missingResource(name):
            return "The  Quran token resource \(name) is missing."
        case let .unreadableResource(reason):
            return "The  Quran token resource is invalid: \(reason)"
        case let .resourceSizeMismatch(expected, actual):
            return "The  Quran token resource size does not match this build (expected \(expected) bytes, found \(actual))."
        case let .resourceHashMismatch(expected, actual):
            return "The  Quran token resource SHA-256 does not match this build (expected \(expected), found \(actual))."
        case let .invalidSchemaVersion(version):
            return "Unsupported  Quran token schema \(version)."
        case .invalidRecordLayout:
            return "The  Quran token record layout does not match this build."
        case let .invalidAyahCount(count):
            return "The  Quran token resource contains \(count) ayahs instead of 6236."
        case let .invalidAyah(surah, ayah, reason):
            return "Invalid  token record \(surah):\(ayah): \(reason)"
        case let .duplicateAyah(surah, ayah):
            return "Duplicate  token record \(surah):\(ayah)."
        case let .missingAyah(surah, ayah):
            return "Missing  token record \(surah):\(ayah)."
        case let .lineRangeMismatch(surah, ayah, range):
            return " line \(range) does not match the pinned token map for \(surah):\(ayah)."
        case let .invalidConfuserPolicy(reason):
            return "The  Quran confuser policy is invalid: \(reason)"
        case let .invalidConfuserLayout(reason):
            return "The  Quran confuser map is invalid: \(reason)"
        }
    }
}

/// Immutable token boundaries generated from 's own Quran corpus.
///
/// No upstream Quran database or copied  span table is consumed at
/// runtime. The generator validates every one of the 6,236 ayahs against the
/// exact  line planner before this compact resource is committed.
final class QuranTokenCatalog: @unchecked Sendable {
    static let resourceName = "quran-token-map"
    static let resourceExtension = "json"
    static let resourceByteCount = 3662707
    static let resourceSHA256 = "ede4fdba97391a631f59324f5836b5ad8cd0d36119837d9af13a2816cc704308"
    static let schemaVersion = 2
    static let confuserPolicyVersion = 1
    static let maximumConfusersPerLine = 16
    static let expectedConfuserCount = 99776
    static let expectedRecordLayout = [
        "surah",
        "ayah",
        "normalized_words",
        "token_ids",
        "word_token_ends",
        "segment_word_ends"
    ]

    private struct Key: Hashable, Sendable {
        let surah: Int
        let ayah: Int
    }

    private struct Record: Decodable, Sendable {
        let surah: Int
        let ayah: Int
        let normalizedWords: [String]
        let tokenIDs: [Int]
        let wordTokenEnds: [Int]
        let segmentWordEnds: [Int]

        init(from decoder: Decoder) throws {
            var values = try decoder.unkeyedContainer()
            surah = try values.decode(Int.self)
            ayah = try values.decode(Int.self)
            normalizedWords = try values.decode([String].self)
            tokenIDs = try values.decode([Int].self)
            wordTokenEnds = try values.decode([Int].self)
            segmentWordEnds = try values.decode([Int].self)
            guard values.isAtEnd else {
                throw DecodingError.dataCorruptedError(
                    in: values,
                    debugDescription: "Unexpected fields in compact ayah record"
                )
            }
        }
    }

    private struct Document: Decodable {
        let schemaVersion: Int
        let recordLayout: [String]
        let ayahs: [Record]
        let lineConfuserPolicy: LineConfuserPolicy
        let lineConfusers: [[Int]]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case recordLayout = "record_layout"
            case ayahs
            case lineConfuserPolicy = "line_confuser_policy"
            case lineConfusers = "line_confusers"
        }
    }

    private struct LineConfuserPolicy: Decodable {
        let version: Int
        let maximumPerLine: Int
        let canonicalLineOrder: String
        let excludedImplicitRuntimeConfusers: [String]

        private enum CodingKeys: String, CodingKey {
            case version
            case maximumPerLine = "maximum_per_line"
            case canonicalLineOrder = "canonical_line_order"
            case excludedImplicitRuntimeConfusers = "excluded_implicit_runtime_confusers"
        }
    }

    private struct LineReference: Equatable, Sendable {
        let key: Key
        let range: Range<Int>
    }

    private let records: [Key: Record]
    private let flattenedLines: [LineReference]
    /// Every canonical one-semantic-word  line. There are only 29, so
    /// scoring the complete set is cheap and avoids a dangerous blind spot in
    /// a directed nearest-neighbor graph for the shortest utterances.
    private let oneWordLines: [LineReference]
    private let lineIndexByIdentity: [String: Int]
    private let lineConfuserIndices: [[Int]]

    init(resourceURL: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: resourceURL, options: [.mappedIfSafe])
        } catch {
            throw QuranTokenCatalogError.unreadableResource(
                error.localizedDescription
            )
        }
        guard data.count == Self.resourceByteCount else {
            throw QuranTokenCatalogError.resourceSizeMismatch(
                expected: Self.resourceByteCount,
                actual: data.count
            )
        }
        let actualSHA256 = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actualSHA256 == Self.resourceSHA256 else {
            throw QuranTokenCatalogError.resourceHashMismatch(
                expected: Self.resourceSHA256,
                actual: actualSHA256
            )
        }

        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw QuranTokenCatalogError.unreadableResource(
                error.localizedDescription
            )
        }
        guard document.schemaVersion == Self.schemaVersion else {
            throw QuranTokenCatalogError.invalidSchemaVersion(
                document.schemaVersion
            )
        }
        guard document.recordLayout == Self.expectedRecordLayout else {
            throw QuranTokenCatalogError.invalidRecordLayout
        }
        guard document.ayahs.count == 6_236 else {
            throw QuranTokenCatalogError.invalidAyahCount(document.ayahs.count)
        }

        var indexed: [Key: Record] = [:]
        indexed.reserveCapacity(document.ayahs.count)
        var lines: [LineReference] = []
        lines.reserveCapacity(6_236)
        var lineIndices: [String: Int] = [:]
        lineIndices.reserveCapacity(6_236)

        for record in document.ayahs {
            try Self.validate(record)
            let key = Key(surah: record.surah, ayah: record.ayah)
            guard indexed.updateValue(record, forKey: key) == nil else {
                throw QuranTokenCatalogError.duplicateAyah(
                    surah: record.surah,
                    ayah: record.ayah
                )
            }

            var lowerBound = 0
            for upperBound in record.segmentWordEnds {
                let reference = LineReference(
                    key: key,
                    range: lowerBound..<upperBound
                )
                let lineIndex = lines.count
                lines.append(reference)
                lineIndices[Self.lineIdentity(key: key, range: reference.range)] = lineIndex
                lowerBound = upperBound
            }
        }

        guard lines.count == 6_236 else {
            throw QuranTokenCatalogError.unreadableResource(
                "expected 6236  lines, found \(lines.count)"
            )
        }
        try Self.validateConfusers(
            policy: document.lineConfuserPolicy,
            rows: document.lineConfusers,
            lines: lines
        )

        records = indexed
        flattenedLines = lines
        oneWordLines = lines.filter { $0.range.count == 1 }
        lineIndexByIdentity = lineIndices
        lineConfuserIndices = document.lineConfusers
    }

    func line(
        surahNumber: Int,
        ayahNumber: Int,
        ayahWordRange: Range<Int>
    ) throws -> QuranTokenLine {
        let key = Key(surah: surahNumber, ayah: ayahNumber)
        guard let record = records[key] else {
            throw QuranTokenCatalogError.missingAyah(
                surah: surahNumber,
                ayah: ayahNumber
            )
        }
        guard !ayahWordRange.isEmpty, ayahWordRange.lowerBound >= 0, ayahWordRange.upperBound <= record.normalizedWords.count else {
            throw QuranTokenCatalogError.lineRangeMismatch(
                surah: surahNumber,
                ayah: ayahNumber,
                range: ayahWordRange
            )
        }
        return Self.makeLine(record: record, range: ayahWordRange)
    }

    /// The exact next canonical  display line inside the selected
    /// Surah. This is passage continuation, not a nearest-neighbour guess.
    /// Callers use it only after the current line's lexical gate is already
    /// satisfied, so speaking a future line cannot skip the durable cursor.
    func immediateFollowingLine(
        surahNumber: Int,
        ayahNumber: Int,
        ayahWordRange: Range<Int>
    ) throws -> QuranTokenLine? {
        let key = Key(surah: surahNumber, ayah: ayahNumber)
        guard let record = records[key] else { return nil }
        if ayahWordRange.upperBound < record.normalizedWords.count {
            return Self.makeLine(record: record, range: ayahWordRange.upperBound..<min(record.normalizedWords.count, ayahWordRange.upperBound + 8))
        }
        let identity = Self.lineIdentity(key: key, range: 0..<record.normalizedWords.count)
        guard let activeIndex = lineIndexByIdentity[identity] else {
            throw QuranTokenCatalogError.lineRangeMismatch(
                surah: surahNumber,
                ayah: ayahNumber,
                range: ayahWordRange
            )
        }

        let nextIndex = activeIndex + 1
        guard flattenedLines.indices.contains(nextIndex) else { return nil }
        let reference = flattenedLines[nextIndex]
        //  sessions never flow from the end of one Surah into another.
        guard reference.key.surah == surahNumber,
              let record = records[reference.key] else { return nil }
        return Self.makeLine(record: record, range: reference.range)
    }

    func normalizedAyahWords(surahNumber: Int, ayahNumber: Int) throws -> [String] {
        let key = Key(surah: surahNumber, ayah: ayahNumber)
        guard let record = records[key] else {
            throw QuranTokenCatalogError.missingAyah(
                surah: surahNumber,
                ayah: ayahNumber
            )
        }
        return record.normalizedWords
    }

    /// Same-ayah siblings, two physically adjacent  lines on either
    /// side, and generated global hard negatives. One-word targets also get
    /// every canonical one-word line because that complete set is tiny.
    /// Every candidate reuses the same logits; no second model pass occurs.
    func nearbyConfusers(
        surahNumber: Int,
        ayahNumber: Int,
        ayahWordRange: Range<Int>
    ) throws -> [QuranTokenLine] {
        let key = Key(surah: surahNumber, ayah: ayahNumber)
        guard let record = records[key] else {
            throw QuranTokenCatalogError.missingAyah(
                surah: surahNumber,
                ayah: ayahNumber
            )
        }
        let identity = Self.lineIdentity(key: key, range: 0..<record.normalizedWords.count)
        guard let activeIndex = lineIndexByIdentity[identity] else {
            throw QuranTokenCatalogError.lineRangeMismatch(
                surah: surahNumber,
                ayah: ayahNumber,
                range: ayahWordRange
            )
        }

        var references = (ayahWordRange == 0..<record.normalizedWords.count ? [] : record.normalizedWords.indices.filter { !ayahWordRange.contains($0) }.map { $0..<($0+1) })
            .filter { $0 != ayahWordRange }
            .map { LineReference(key: key, range: $0) }

        let lower = max(flattenedLines.startIndex, activeIndex - 2)
        let upper = min(flattenedLines.endIndex, activeIndex + 3)
        references.append(contentsOf: flattenedLines[lower..<upper])
        references.append(
            contentsOf: lineConfuserIndices[activeIndex].map { flattenedLines[$0] }
        )
        if ayahWordRange.count == 1 {
            // A one-word line has too little lexical context for a sparse,
            // directed neighbor list to be authoritative. Compare it against
            // the entire tiny canonical L1 set so the actually spoken word is
            // always in the denominator when the selected target is wrong.
            references.append(contentsOf: oneWordLines)
        }

        var seen: Set<String> = []
        return references.compactMap { reference in
            let candidateIdentity = Self.lineIdentity(
                key: reference.key,
                range: reference.range
            )
            guard candidateIdentity != identity,
                  seen.insert(candidateIdentity).inserted,
                  let candidateRecord = records[reference.key] else {
                return nil
            }
            return Self.makeLine(record: candidateRecord, range: reference.range)
        }
    }

    private static func validate(_ record: Record) throws {
        func invalid(_ reason: String) -> QuranTokenCatalogError {
            .invalidAyah(surah: record.surah, ayah: record.ayah, reason: reason)
        }

        guard (1...114).contains(record.surah), record.ayah > 0 else {
            throw invalid("invalid Quran location")
        }
        guard !record.normalizedWords.isEmpty,
              record.normalizedWords.allSatisfy({ !$0.isEmpty }) else {
            throw invalid("empty normalized words")
        }
        guard !record.tokenIDs.isEmpty,
              record.tokenIDs.allSatisfy({ (0..<1_024).contains($0) }) else {
            throw invalid("token IDs must be model non-blank IDs")
        }
        guard record.wordTokenEnds.count == record.normalizedWords.count,
              strictlyIncreasing(record.wordTokenEnds),
              record.wordTokenEnds.last == record.tokenIDs.count else {
            throw invalid("word token boundaries do not cover the token sequence")
        }
        guard !record.segmentWordEnds.isEmpty,
              strictlyIncreasing(record.segmentWordEnds),
              record.segmentWordEnds.last == record.normalizedWords.count else {
            throw invalid(" line boundaries do not cover the ayah words")
        }
    }

    private static func validateConfusers(
        policy: LineConfuserPolicy,
        rows: [[Int]],
        lines: [LineReference]
    ) throws {
        guard policy.version == confuserPolicyVersion else {
            throw QuranTokenCatalogError.invalidConfuserPolicy(
                "expected version \(confuserPolicyVersion), found \(policy.version)"
            )
        }
        guard policy.maximumPerLine == maximumConfusersPerLine else {
            throw QuranTokenCatalogError.invalidConfuserPolicy(
                "expected a maximum of \(maximumConfusersPerLine), found \(policy.maximumPerLine)"
            )
        }
        guard policy.canonicalLineOrder ==
                "ayah record order, then segment_word_ends order within each ayah" else {
            throw QuranTokenCatalogError.invalidConfuserPolicy(
                "unexpected canonical line ordering"
            )
        }
        guard policy.excludedImplicitRuntimeConfusers == [
            "same-ayah sibling lines",
            "canonical global line index +/-2"
        ] else {
            throw QuranTokenCatalogError.invalidConfuserPolicy(
                "unexpected implicit-confuser exclusions"
            )
        }
        guard rows.count == lines.count else {
            throw QuranTokenCatalogError.invalidConfuserLayout(
                "expected \(lines.count) rows, found \(rows.count)"
            )
        }
        guard rows.reduce(0, { $0 + $1.count }) == expectedConfuserCount else {
            throw QuranTokenCatalogError.invalidConfuserLayout(
                "expected \(expectedConfuserCount) candidate indices"
            )
        }

        for (lineIndex, candidates) in rows.enumerated() {
            guard !candidates.isEmpty,
                  candidates.count <= maximumConfusersPerLine else {
                throw QuranTokenCatalogError.invalidConfuserLayout(
                    "line \(lineIndex) has \(candidates.count) candidates"
                )
            }
            guard Set(candidates).count == candidates.count else {
                throw QuranTokenCatalogError.invalidConfuserLayout(
                    "line \(lineIndex) contains duplicate candidates"
                )
            }
            for candidateIndex in candidates {
                guard lines.indices.contains(candidateIndex) else {
                    throw QuranTokenCatalogError.invalidConfuserLayout(
                        "line \(lineIndex) references out-of-range line \(candidateIndex)"
                    )
                }
                guard abs(candidateIndex - lineIndex) > 2 else {
                    throw QuranTokenCatalogError.invalidConfuserLayout(
                        "line \(lineIndex) repeats an implicit adjacent candidate"
                    )
                }
                guard lines[candidateIndex].key != lines[lineIndex].key else {
                    throw QuranTokenCatalogError.invalidConfuserLayout(
                        "line \(lineIndex) repeats an implicit same-ayah candidate"
                    )
                }
            }
        }
    }

    private static func strictlyIncreasing(_ values: [Int]) -> Bool {
        guard let first = values.first, first > 0 else { return false }
        return zip(values, values.dropFirst()).allSatisfy(<)
    }

    private static func lineRanges(for record: Record) -> [Range<Int>] {
        var lowerBound = 0
        return record.segmentWordEnds.map { upperBound in
            defer { lowerBound = upperBound }
            return lowerBound..<upperBound
        }
    }

    private static func makeLine(
        record: Record,
        range: Range<Int>
    ) -> QuranTokenLine {
        let tokenStart = range.lowerBound == 0
            ? 0
            : record.wordTokenEnds[range.lowerBound - 1]
        let tokenEnd = record.wordTokenEnds[range.upperBound - 1]
        return QuranTokenLine(
            surahNumber: record.surah,
            ayahNumber: record.ayah,
            ayahWordRange: range,
            normalizedWords: Array(record.normalizedWords[range]),
            tokenIDs: Array(record.tokenIDs[tokenStart..<tokenEnd]),
            wordTokenEnds: range.map {
                record.wordTokenEnds[$0] - tokenStart
            }
        )
    }

    private static func lineIdentity(key: Key, range: Range<Int>) -> String {
        "\(key.surah):\(key.ayah):\(range.lowerBound)-\(range.upperBound)"
    }
}
