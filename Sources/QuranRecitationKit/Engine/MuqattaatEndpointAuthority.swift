import Foundation

/// The eight disconnected-letter forms that are rendered as a standalone,
/// one-semantic-word  line by the pinned line planner.
///
/// Other Muqatta'at openings are followed by ordinary Quran words inside the
/// same  line. Their later words already give the regular CTC evaluator
/// an unambiguous endpoint, so they must not enter this special path.
enum MuqattaatForm: String, CaseIterable, Codable, Sendable {
    case alifLamMim = "الم"
    case alifLamMimSad = "المص"
    case kafHaYaAynSad = "كهيعص"
    case taHa = "طه"
    case taSinMim = "طسم"
    case yaSin = "يس"
    case haMim = "حم"
    case aynSinQaf = "عسق"

    /// ASCII identifier used by generated artifacts. Arabic presentation text
    /// is never used as an implicit filename or binary-layout key.
    var profileID: String {
        switch self {
        case .alifLamMim: "alm"
        case .alifLamMimSad: "almsad"
        case .kafHaYaAynSad: "khyaas"
        case .taHa: "taha"
        case .taSinMim: "tasm"
        case .yaSin: "yasin"
        case .haMim: "hamim"
        case .aynSinQaf: "asq"
        }
    }

    init?(profileID: String) {
        guard let form = Self.allCases.first(where: { $0.profileID == profileID }) else {
            return nil
        }
        self = form
    }

    /// Canonical Quran token IDs emitted by the pinned  tokenizer. These
    /// describe line identity only; the acoustic endpoint verifier does not
    /// pretend that one canonical token equals one spoken disconnected letter.
    var canonicalTokenIDs: [Int] {
        switch self {
        case .alifLamMim: [31]
        case .alifLamMimSad: [31, 45]
        case .kafHaYaAynSad: [95, 3, 2, 13, 45]
        case .taHa: [133, 3]
        case .taSinMim: [133, 26, 7]
        case .yaSin: [22, 26]
        case .haMim: [73, 7]
        case .aynSinQaf: [66, 26, 32]
        }
    }

    /// The number of disconnected letters spoken for this standalone form.
    ///
    ///  renders each form as one semantic word, while recitation takes
    /// materially longer than an ordinary one-word line. Automatic completion
    /// therefore uses this count only for its speech-span floor; transcript
    /// coverage still requires the exact single displayed word.
    var spokenLetterCount: Int {
        switch self {
        case .alifLamMim: 3
        case .alifLamMimSad: 4
        case .kafHaYaAynSad: 5
        case .taHa: 2
        case .taSinMim: 3
        case .yaSin: 2
        case .haMim: 2
        case .aynSinQaf: 3
        }
    }
}

struct MuqattaatLineLocation: Hashable, Codable, Sendable {
    let surahNumber: Int
    let ayahNumber: Int
    let wordRangeLowerBound: Int
    let wordRangeUpperBound: Int

    init(
        surahNumber: Int,
        ayahNumber: Int,
        ayahWordRange: Range<Int>
    ) {
        self.surahNumber = surahNumber
        self.ayahNumber = ayahNumber
        wordRangeLowerBound = ayahWordRange.lowerBound
        wordRangeUpperBound = ayahWordRange.upperBound
    }

    var ayahWordRange: Range<Int> {
        wordRangeLowerBound..<wordRangeUpperBound
    }
}

struct MuqattaatEndpointAuthority: Equatable, Sendable {
    let location: MuqattaatLineLocation
    let form: MuqattaatForm

    var expectedNormalizedWords: [String] { [form.rawValue] }
    var expectedCanonicalTokenIDs: [Int] { form.canonicalTokenIDs }
}

/// Exact current-window token evidence used by the automatic standalone path.
/// Leading decoded material is tolerated because the rolling inference window
/// can contain earlier noise or context. A proper prefix and any token after
/// the canonical form both fail, so an early target emission cannot remain
/// authoritative after the decoder observes a different suffix.
enum MuqattaatAutomaticIdentity {
    static func decision(
        decodedTokenIDs: [Int],
        authority: MuqattaatEndpointAuthority
    ) -> AcousticDecision {
        hasCanonicalTargetSuffix(
            decodedTokenIDs: decodedTokenIDs,
            authority: authority
        ) ? .identityMatched : .rejected
    }

    static func hasCanonicalTargetSuffix(
        decodedTokenIDs: [Int],
        authority: MuqattaatEndpointAuthority
    ) -> Bool {
        let target = authority.expectedCanonicalTokenIDs
        guard !target.isEmpty, decodedTokenIDs.count >= target.count else {
            return false
        }
        return decodedTokenIDs.suffix(target.count).elementsEqual(target)
    }
}

enum MuqattaatEndpointAuthorityError: Error, Equatable, Sendable {
    case duplicateLocation(MuqattaatLineLocation)
    case invalidAuthorityCount(expected: Int, actual: Int)
    case missingForm(MuqattaatForm)
    case catalogMismatch(
        location: MuqattaatLineLocation,
        expectedWords: [String],
        actualWords: [String],
        expectedTokenIDs: [Int],
        actualTokenIDs: [Int]
    )
    case unexpectedStandaloneForm(
        location: MuqattaatLineLocation,
        form: MuqattaatForm
    )
}

extension MuqattaatEndpointAuthorityError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .duplicateLocation(location):
            return "Duplicate Muqatta'at endpoint authority at \(location.surahNumber):\(location.ayahNumber)."
        case let .invalidAuthorityCount(expected, actual):
            return "The Muqatta'at endpoint table contains \(actual) lines instead of \(expected)."
        case let .missingForm(form):
            return "The Muqatta'at endpoint table does not cover \(form.rawValue)."
        case let .catalogMismatch(location, _, _, _, _):
            return "The Quran token catalog does not match the Muqatta'at endpoint authority at \(location.surahNumber):\(location.ayahNumber)."
        case let .unexpectedStandaloneForm(location, form):
            return "Unexpected standalone Muqatta'at form \(form.rawValue) at \(location.surahNumber):\(location.ayahNumber)."
        }
    }
}

/// Frozen identity resolver for the exact planner/token-map pair shipped by
/// this release. A known special location with changed text or token IDs throws
/// instead of silently applying an automatic policy to the wrong Quran text.
enum MuqattaatEndpointAuthorityResolver {
    static let expectedAuthorityCount = 20

    private static func authority(
        _ surah: Int,
        _ ayah: Int,
        _ form: MuqattaatForm
    ) -> MuqattaatEndpointAuthority {
        MuqattaatEndpointAuthority(
            location: MuqattaatLineLocation(
                surahNumber: surah,
                ayahNumber: ayah,
                ayahWordRange: 0..<1
            ),
            form: form
        )
    }

    static let allAuthorities: [MuqattaatEndpointAuthority] = [
        authority(2, 1, .alifLamMim),
        authority(3, 1, .alifLamMim),
        authority(7, 1, .alifLamMimSad),
        authority(19, 1, .kafHaYaAynSad),
        authority(20, 1, .taHa),
        authority(26, 1, .taSinMim),
        authority(28, 1, .taSinMim),
        authority(29, 1, .alifLamMim),
        authority(30, 1, .alifLamMim),
        authority(31, 1, .alifLamMim),
        authority(32, 1, .alifLamMim),
        authority(36, 1, .yaSin),
        authority(40, 1, .haMim),
        authority(41, 1, .haMim),
        authority(42, 1, .haMim),
        authority(42, 2, .aynSinQaf),
        authority(43, 1, .haMim),
        authority(44, 1, .haMim),
        authority(45, 1, .haMim),
        authority(46, 1, .haMim),
    ]

    private static let byLocation: [
        MuqattaatLineLocation: MuqattaatEndpointAuthority
    ] = Dictionary(
        uniqueKeysWithValues: allAuthorities.map { ($0.location, $0) }
    )

    /// Resolves target configuration before microphone capture starts. Token
    /// IDs are unavailable at this layer, so the location and normalized text
    /// are checked here; the acoustic evaluator performs the full token check
    /// against the pinned catalog before scoring the same target.
    static func resolveAutomaticTarget(
        surahNumber: Int,
        ayahNumber: Int,
        ayahWordRange: Range<Int>,
        normalizedWords: [String]
    ) throws -> MuqattaatEndpointAuthority? {
        let location = MuqattaatLineLocation(
            surahNumber: surahNumber,
            ayahNumber: ayahNumber,
            ayahWordRange: ayahWordRange
        )
        if let expected = byLocation[location] {
            guard normalizedWords == expected.expectedNormalizedWords else {
                throw MuqattaatEndpointAuthorityError.catalogMismatch(
                    location: location,
                    expectedWords: expected.expectedNormalizedWords,
                    actualWords: normalizedWords,
                    expectedTokenIDs: expected.expectedCanonicalTokenIDs,
                    actualTokenIDs: []
                )
            }
            return expected
        }

        if ayahWordRange.count == 1,
           normalizedWords.count == 1,
           let form = MuqattaatForm(rawValue: normalizedWords[0]) {
            throw MuqattaatEndpointAuthorityError.unexpectedStandaloneForm(
                location: location,
                form: form
            )
        }
        return nil
    }

    /// Returns nil only for a genuinely ordinary line. A mismatch at one of
    /// the 20 frozen locations, or a new standalone occurrence introduced by
    /// planner drift, fails as a configuration error rather than entering a
    /// different completion mode.
    static func resolve(
        surahNumber: Int,
        ayahNumber: Int,
        ayahWordRange: Range<Int>,
        normalizedWords: [String],
        canonicalTokenIDs: [Int]
    ) throws -> MuqattaatEndpointAuthority? {
        let location = MuqattaatLineLocation(
            surahNumber: surahNumber,
            ayahNumber: ayahNumber,
            ayahWordRange: ayahWordRange
        )
        if let expected = byLocation[location] {
            guard normalizedWords == expected.expectedNormalizedWords,
                  canonicalTokenIDs == expected.expectedCanonicalTokenIDs else {
                throw MuqattaatEndpointAuthorityError.catalogMismatch(
                    location: location,
                    expectedWords: expected.expectedNormalizedWords,
                    actualWords: normalizedWords,
                    expectedTokenIDs: expected.expectedCanonicalTokenIDs,
                    actualTokenIDs: canonicalTokenIDs
                )
            }
            return expected
        }

        if ayahWordRange.count == 1,
           normalizedWords.count == 1,
           let form = MuqattaatForm(rawValue: normalizedWords[0]) {
            throw MuqattaatEndpointAuthorityError.unexpectedStandaloneForm(
                location: location,
                form: form
            )
        }
        return nil
    }

    static func validateFrozenContract() throws {
        guard allAuthorities.count == expectedAuthorityCount,
              byLocation.count == expectedAuthorityCount else {
            throw MuqattaatEndpointAuthorityError.invalidAuthorityCount(
                expected: expectedAuthorityCount,
                actual: byLocation.count
            )
        }
        for form in MuqattaatForm.allCases
        where !allAuthorities.contains(where: { $0.form == form }) {
            throw MuqattaatEndpointAuthorityError.missingForm(form)
        }
    }
}
