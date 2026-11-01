import Foundation

// MARK: - Immutable canonical Surah index

/// One normalized Quran word before it receives its immutable Surah-global
/// position. Text normalization and token-catalog validation belong to the
/// integration boundary; this pure core deliberately owns neither resource.
struct SurahCanonicalWordSource: Equatable, Sendable {
    let normalizedText: String
    let acceptedNormalizedVariants: [String]
    let ayahNumber: Int
    let ayahWordIndex: Int
    let segmentIndex: Int

    init(
        normalizedText: String,
        acceptedNormalizedVariants: [String] = [],
        ayahNumber: Int,
        ayahWordIndex: Int,
        segmentIndex: Int
    ) {
        self.normalizedText = normalizedText
        self.acceptedNormalizedVariants = acceptedNormalizedVariants
        self.ayahNumber = ayahNumber
        self.ayahWordIndex = ayahWordIndex
        self.segmentIndex = segmentIndex
    }
}

/// One word in the flattened, canonical sequence for a selected Surah.
///
/// Recognition advances through `surahWordIndex`. Ayah and display-line
/// coordinates are lookup metadata only; neither can retarget recognition.
struct SurahCanonicalWord: Identifiable, Equatable, Sendable {
    let surahWordIndex: Int
    let normalizedText: String
    let acceptedNormalizedVariants: [String]
    let ayahNumber: Int
    let ayahWordIndex: Int
    let segmentIndex: Int

    var id: Int { surahWordIndex }

    /// Primary spelling followed by bounded, audited pronunciation spellings.
    var normalizedForms: [String] {
        [normalizedText] + acceptedNormalizedVariants
    }
}

struct SurahExpectedWindowLimits: Equatable, Sendable {
    /// Previously verified context retained for rolling-window anchoring.
    let backtrackWordCount: Int
    /// Absolute bound independent of Surah length.
    let maximumLookaheadWordCount: Int
    /// Includes the line containing the cursor. The live bound is deliberately
    /// large enough to cover all four Al-Ikhlas lines in one fast observation,
    /// while the absolute word bound keeps work independent of Surah length.
    let maximumForwardSegmentCount: Int

    static let live = Self(
        backtrackWordCount: 3,
        maximumLookaheadWordCount: 32,
        maximumForwardSegmentCount: 4
    )
}

struct SurahExpectedWindow: Equatable, Sendable {
    let surahNumber: Int
    let verifiedCursor: Int
    let globalWordRange: Range<Int>
    let words: [SurahCanonicalWord]

    var anchorLocalIndex: Int {
        verifiedCursor - globalWordRange.lowerBound
    }
}

enum CanonicalWordIndexError: Error, Equatable, Sendable {
    case invalidSurahNumber(Int)
    case emptySurah
    case emptyNormalizedWord(index: Int)
    case normalizedWordContainsWhitespace(index: Int)
    case invalidAyahNumber(index: Int, value: Int)
    case invalidAyahWordIndex(index: Int, value: Int)
    case invalidSegmentIndex(index: Int, value: Int)
    case nonSequentialAyahWord(index: Int)
    case nonSequentialSegment(index: Int)
    case invalidWindowLimits
    case cursorOutsideSurah(Int)
}

/// Immutable flat word/index map constructed once per Surah and corpus
/// version. It contains no audio, model, UI, or durable  state.
struct CanonicalWordIndex: Equatable, Sendable {
    let surahNumber: Int
    let words: [SurahCanonicalWord]
    let segmentWordRanges: [Range<Int>]

    init(
        surahNumber: Int,
        wordSources: [SurahCanonicalWordSource]
    ) throws {
        guard (1...114).contains(surahNumber) else {
            throw CanonicalWordIndexError.invalidSurahNumber(surahNumber)
        }
        guard !wordSources.isEmpty else {
            throw CanonicalWordIndexError.emptySurah
        }

        var canonicalWords: [SurahCanonicalWord] = []
        canonicalWords.reserveCapacity(wordSources.count)

        for (index, source) in wordSources.enumerated() {
            let primary = source.normalizedText.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !primary.isEmpty else {
                throw CanonicalWordIndexError.emptyNormalizedWord(index: index)
            }
            guard !primary.contains(where: { $0.isWhitespace }) else {
                throw CanonicalWordIndexError
                    .normalizedWordContainsWhitespace(index: index)
            }
            guard source.ayahNumber > 0 else {
                throw CanonicalWordIndexError.invalidAyahNumber(
                    index: index,
                    value: source.ayahNumber
                )
            }
            guard source.ayahWordIndex >= 0 else {
                throw CanonicalWordIndexError.invalidAyahWordIndex(
                    index: index,
                    value: source.ayahWordIndex
                )
            }
            guard source.segmentIndex >= 0 else {
                throw CanonicalWordIndexError.invalidSegmentIndex(
                    index: index,
                    value: source.segmentIndex
                )
            }

            if let prior = canonicalWords.last {
                let ayahPositionIsSequential: Bool
                if source.ayahNumber == prior.ayahNumber {
                    ayahPositionIsSequential = source.ayahWordIndex
                        == prior.ayahWordIndex + 1
                } else {
                    ayahPositionIsSequential = source.ayahNumber > prior.ayahNumber
                        && source.ayahWordIndex == 0
                }
                guard ayahPositionIsSequential else {
                    throw CanonicalWordIndexError
                        .nonSequentialAyahWord(index: index)
                }

                guard source.segmentIndex == prior.segmentIndex
                        || source.segmentIndex == prior.segmentIndex + 1 else {
                    throw CanonicalWordIndexError
                        .nonSequentialSegment(index: index)
                }
            } else {
                guard source.ayahWordIndex == 0 else {
                    throw CanonicalWordIndexError
                        .nonSequentialAyahWord(index: index)
                }
                guard source.segmentIndex == 0 else {
                    throw CanonicalWordIndexError
                        .nonSequentialSegment(index: index)
                }
            }

            var variants: [String] = []
            var seenForms: Set<String> = [primary]
            for rawVariant in source.acceptedNormalizedVariants {
                let variant = rawVariant.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !variant.isEmpty,
                      !variant.contains(where: { $0.isWhitespace }),
                      seenForms.insert(variant).inserted else {
                    continue
                }
                variants.append(variant)
            }

            canonicalWords.append(SurahCanonicalWord(
                surahWordIndex: index,
                normalizedText: primary,
                acceptedNormalizedVariants: variants,
                ayahNumber: source.ayahNumber,
                ayahWordIndex: source.ayahWordIndex,
                segmentIndex: source.segmentIndex
            ))
        }

        var lineRanges: [Range<Int>] = []
        var lineStart = 0
        var activeLine = canonicalWords[0].segmentIndex
        for index in canonicalWords.indices.dropFirst() {
            let line = canonicalWords[index].segmentIndex
            guard line != activeLine else { continue }
            lineRanges.append(lineStart..<index)
            lineStart = index
            activeLine = line
        }
        lineRanges.append(lineStart..<canonicalWords.count)

        self.surahNumber = surahNumber
        words = canonicalWords
        segmentWordRanges = lineRanges
    }

    var wordCount: Int { words.count }
    var segmentCount: Int { segmentWordRanges.count }

    func word(at index: Int) -> SurahCanonicalWord? {
        words.indices.contains(index) ? words[index] : nil
    }

    func segmentIndex(containingWordAt wordIndex: Int) -> Int? {
        guard words.indices.contains(wordIndex) else { return nil }
        return words[wordIndex].segmentIndex
    }

    /// The line containing the next unverified word. At the terminal cursor it
    /// resolves to the final line so completion UI has stable metadata.
    func segmentIndex(atOrAfterCursor cursor: Int) -> Int? {
        guard (0...wordCount).contains(cursor) else { return nil }
        if cursor == wordCount {
            return words.last?.segmentIndex
        }
        return words[cursor].segmentIndex
    }

    func expectedWindow(
        aroundVerifiedCursor cursor: Int,
        limits: SurahExpectedWindowLimits = .live
    ) throws -> SurahExpectedWindow {
        guard (0...wordCount).contains(cursor) else {
            throw CanonicalWordIndexError.cursorOutsideSurah(cursor)
        }
        guard limits.backtrackWordCount >= 0,
              limits.maximumLookaheadWordCount > 0,
              limits.maximumForwardSegmentCount > 0 else {
            throw CanonicalWordIndexError.invalidWindowLimits
        }
        guard cursor < wordCount else {
            return SurahExpectedWindow(
                surahNumber: surahNumber,
                verifiedCursor: cursor,
                globalWordRange: cursor..<cursor,
                words: []
            )
        }

        let lowerBound = max(0, cursor - limits.backtrackWordCount)
        let currentLineIndex = words[cursor].segmentIndex
        let finalIncludedLineIndex = min(
            segmentWordRanges.count - 1,
            currentLineIndex + limits.maximumForwardSegmentCount - 1
        )
        let displayBound = segmentWordRanges[finalIncludedLineIndex].upperBound
        let wordBound = min(
            wordCount,
            cursor + limits.maximumLookaheadWordCount
        )
        let upperBound = max(cursor + 1, min(displayBound, wordBound))
        let range = lowerBound..<upperBound
        return SurahExpectedWindow(
            surahNumber: surahNumber,
            verifiedCursor: cursor,
            globalWordRange: range,
            words: Array(words[range])
        )
    }
}

// MARK: - Positional anchored word alignment

struct AnchoredWordAlignmentConfiguration: Equatable, Sendable {
    let minimumLexicalSimilarity: Double
    let strongLexicalSimilarity: Double
    /// Tolerates decoder insertions between two consecutive expected words.
    /// Expected-word deletion is never credited.
    let maximumDecodedInsertionsBetweenWords: Int
    let maximumDecodedWordCount: Int

    static let live = Self(
        minimumLexicalSimilarity: 0.70,
        strongLexicalSimilarity: 0.88,
        maximumDecodedInsertionsBetweenWords: 2,
        maximumDecodedWordCount: 32
    )

    var isValid: Bool {
        minimumLexicalSimilarity.isFinite
            && strongLexicalSimilarity.isFinite
            && (0...1).contains(minimumLexicalSimilarity)
            && (minimumLexicalSimilarity...1).contains(strongLexicalSimilarity)
            && maximumDecodedInsertionsBetweenWords >= 0
            && maximumDecodedWordCount > 0
    }
}

struct AnchoredWordMatch: Equatable, Sendable {
    let expectedSurahWordIndex: Int
    let decodedWordIndex: Int
    let lexicalSimilarity: Double
}

struct AnchoredWordAlignment: Equatable, Sendable {
    let verifiedCursor: Int
    /// Always begins exactly at `verifiedCursor`. There is no API representing
    /// a located occurrence elsewhere in lookahead.
    let contiguousExpectedWordRange: Range<Int>
    let matches: [AnchoredWordMatch]
    let matchedBacktrackWordCount: Int
    let nextExpectedWordCandidateDecodedIndex: Int?
    let nextExpectedWordCandidateSimilarity: Double

    var isEmpty: Bool { contiguousExpectedWordRange.isEmpty }
}

enum AnchoredWordAligner {
    private struct DecodedWord {
        let originalIndex: Int
        let text: String
    }

    private struct Candidate {
        let matches: [AnchoredWordMatch]
        let matchedBacktrackWordCount: Int
        let meanSimilarity: Double
        let decodedAnchorIndex: Int
        let finalDecodedArrayIndex: Int
    }

    /// Aligns only the continuation beginning at the verified cursor.
    ///
    /// The implementation may ignore decoded prefix noise and may tolerate a
    /// bounded number of decoded insertions. It never skips an expected word,
    /// never searches for a phrase at a later expected position, and never
    /// compares model token sequences for equality.
    static func align(
        decodedNormalizedWords: [String],
        in window: SurahExpectedWindow,
        configuration: AnchoredWordAlignmentConfiguration = .live
    ) -> AnchoredWordAlignment {
        guard configuration.isValid,
              window.globalWordRange.contains(window.verifiedCursor),
              window.words.count == window.globalWordRange.count else {
            return emptyAlignment(window: window)
        }

        let nonemptyDecoded = decodedNormalizedWords.enumerated().compactMap {
            index, raw -> DecodedWord? in
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : DecodedWord(originalIndex: index, text: text)
        }
        let decoded = Array(nonemptyDecoded.suffix(configuration.maximumDecodedWordCount))
        guard !decoded.isEmpty else { return emptyAlignment(window: window) }

        let anchorLocalIndex = window.anchorLocalIndex
        guard window.words.indices.contains(anchorLocalIndex) else {
            return emptyAlignment(window: window)
        }
        let anchorWord = window.words[anchorLocalIndex]

        var bestCandidate: Candidate?
        for decodedAnchorArrayIndex in decoded.indices {
            let anchorSimilarity = lexicalSimilarity(
                decoded[decodedAnchorArrayIndex].text,
                forms: anchorWord.normalizedForms
            )
            guard anchorSimilarity >= configuration.minimumLexicalSimilarity else {
                continue
            }

            var matches = [AnchoredWordMatch(
                expectedSurahWordIndex: window.verifiedCursor,
                decodedWordIndex: decoded[decodedAnchorArrayIndex].originalIndex,
                lexicalSimilarity: anchorSimilarity
            )]
            var priorDecodedArrayIndex = decodedAnchorArrayIndex
            var expectedLocalIndex = anchorLocalIndex + 1

            while expectedLocalIndex < window.words.count {
                let lowerDecodedIndex = priorDecodedArrayIndex + 1
                guard lowerDecodedIndex < decoded.count else { break }
                let upperDecodedIndex = min(
                    decoded.count - 1,
                    lowerDecodedIndex
                        + configuration.maximumDecodedInsertionsBetweenWords
                )
                let expectedWord = window.words[expectedLocalIndex]
                guard let next = bestDecodedMatch(
                    for: expectedWord,
                    decoded: decoded,
                    range: lowerDecodedIndex...upperDecodedIndex,
                    minimumSimilarity: configuration.minimumLexicalSimilarity
                ) else {
                    // An expected deletion is a hard positional boundary.
                    break
                }
                matches.append(AnchoredWordMatch(
                    expectedSurahWordIndex: expectedWord.surahWordIndex,
                    decodedWordIndex: decoded[next.index].originalIndex,
                    lexicalSimilarity: next.similarity
                ))
                priorDecodedArrayIndex = next.index
                expectedLocalIndex += 1
            }

            let backtrackCount = matchedBacktrackCount(
                beforeExpectedLocalIndex: anchorLocalIndex,
                beforeDecodedArrayIndex: decodedAnchorArrayIndex,
                expected: window.words,
                decoded: decoded,
                configuration: configuration
            )
            let mean = matches.reduce(0) { $0 + $1.lexicalSimilarity }
                / Double(matches.count)
            let candidate = Candidate(
                matches: matches,
                matchedBacktrackWordCount: backtrackCount,
                meanSimilarity: mean,
                decodedAnchorIndex: decoded[decodedAnchorArrayIndex].originalIndex,
                finalDecodedArrayIndex: priorDecodedArrayIndex
            )
            if isPreferred(candidate, over: bestCandidate) {
                bestCandidate = candidate
            }
        }

        guard let bestCandidate else {
            let next = strongestDecodedCandidate(
                for: anchorWord,
                decoded: decoded,
                range: decoded.indices
            )
            return AnchoredWordAlignment(
                verifiedCursor: window.verifiedCursor,
                contiguousExpectedWordRange:
                    window.verifiedCursor..<window.verifiedCursor,
                matches: [],
                matchedBacktrackWordCount: 0,
                nextExpectedWordCandidateDecodedIndex:
                    next.map { decoded[$0.index].originalIndex },
                nextExpectedWordCandidateSimilarity: next?.similarity ?? 0
            )
        }

        let upperBound = window.verifiedCursor + bestCandidate.matches.count
        let nextExpectedLocalIndex = window.anchorLocalIndex
            + bestCandidate.matches.count
        let nextCandidate: (index: Int, similarity: Double)?
        if window.words.indices.contains(nextExpectedLocalIndex) {
            let lower = bestCandidate.finalDecodedArrayIndex + 1
            if lower < decoded.count {
                let upper = min(
                    decoded.count - 1,
                    lower + configuration.maximumDecodedInsertionsBetweenWords
                )
                nextCandidate = strongestDecodedCandidate(
                    for: window.words[nextExpectedLocalIndex],
                    decoded: decoded,
                    range: lower...upper
                )
            } else {
                nextCandidate = nil
            }
        } else {
            nextCandidate = nil
        }

        return AnchoredWordAlignment(
            verifiedCursor: window.verifiedCursor,
            contiguousExpectedWordRange: window.verifiedCursor..<upperBound,
            matches: bestCandidate.matches,
            matchedBacktrackWordCount: bestCandidate.matchedBacktrackWordCount,
            nextExpectedWordCandidateDecodedIndex:
                nextCandidate.map { decoded[$0.index].originalIndex },
            nextExpectedWordCandidateSimilarity: nextCandidate?.similarity ?? 0
        )
    }

    private static func emptyAlignment(
        window: SurahExpectedWindow
    ) -> AnchoredWordAlignment {
        AnchoredWordAlignment(
            verifiedCursor: window.verifiedCursor,
            contiguousExpectedWordRange:
                window.verifiedCursor..<window.verifiedCursor,
            matches: [],
            matchedBacktrackWordCount: 0,
            nextExpectedWordCandidateDecodedIndex: nil,
            nextExpectedWordCandidateSimilarity: 0
        )
    }

    private static func isPreferred(
        _ candidate: Candidate,
        over existing: Candidate?
    ) -> Bool {
        guard let existing else { return true }
        if candidate.matches.count != existing.matches.count {
            return candidate.matches.count > existing.matches.count
        }
        if candidate.matchedBacktrackWordCount != existing.matchedBacktrackWordCount {
            return candidate.matchedBacktrackWordCount
                > existing.matchedBacktrackWordCount
        }
        if candidate.meanSimilarity != existing.meanSimilarity {
            return candidate.meanSimilarity > existing.meanSimilarity
        }
        // Prefer the most recent equivalent occurrence in a rolling decode.
        return candidate.decodedAnchorIndex > existing.decodedAnchorIndex
    }

    private static func bestDecodedMatch(
        for word: SurahCanonicalWord,
        decoded: [DecodedWord],
        range: ClosedRange<Int>,
        minimumSimilarity: Double
    ) -> (index: Int, similarity: Double)? {
        guard let strongest = strongestDecodedCandidate(
            for: word,
            decoded: decoded,
            range: range
        ), strongest.similarity >= minimumSimilarity else {
            return nil
        }
        return strongest
    }

    private static func strongestDecodedCandidate(
        for word: SurahCanonicalWord,
        decoded: [DecodedWord],
        range: some Sequence<Int>
    ) -> (index: Int, similarity: Double)? {
        var best: (index: Int, similarity: Double)?
        for index in range where decoded.indices.contains(index) {
            let similarity = lexicalSimilarity(
                decoded[index].text,
                forms: word.normalizedForms
            )
            if best == nil || similarity > best!.similarity {
                best = (index, similarity)
            }
        }
        return best
    }

    private static func matchedBacktrackCount(
        beforeExpectedLocalIndex expectedStart: Int,
        beforeDecodedArrayIndex decodedStart: Int,
        expected: [SurahCanonicalWord],
        decoded: [DecodedWord],
        configuration: AnchoredWordAlignmentConfiguration
    ) -> Int {
        guard expectedStart > 0, decodedStart > 0 else { return 0 }
        var expectedIndex = expectedStart - 1
        var decodedUpper = decodedStart - 1
        var count = 0

        while expected.indices.contains(expectedIndex), decodedUpper >= 0 {
            let decodedLower = max(
                0,
                decodedUpper - configuration.maximumDecodedInsertionsBetweenWords
            )
            guard let match = bestDecodedMatch(
                for: expected[expectedIndex],
                decoded: decoded,
                range: decodedLower...decodedUpper,
                minimumSimilarity: configuration.minimumLexicalSimilarity
            ) else {
                break
            }
            count += 1
            guard expectedIndex > 0, match.index > 0 else { break }
            expectedIndex -= 1
            decodedUpper = match.index - 1
        }
        return count
    }

    private static func lexicalSimilarity(
        _ decoded: String,
        forms: [String]
    ) -> Double {
        forms.reduce(0) { best, form in
            max(best, levenshteinRatio(decoded, form))
        }
    }

    /// `(len(a) + len(b) - distance) / (len(a) + len(b))`, matching the
    /// existing  word normalizer's tolerant word-domain convention.
    private static func levenshteinRatio(_ first: String, _ second: String) -> Double {
        let lhs = Array(first)
        let rhs = Array(second)
        let lengthSum = lhs.count + rhs.count
        guard lengthSum > 0 else { return 1 }
        let distance = levenshteinDistance(lhs, rhs)
        return Double(lengthSum - distance) / Double(lengthSum)
    }

    private static func levenshteinDistance(
        _ first: [Character],
        _ second: [Character]
    ) -> Int {
        if first == second { return 0 }
        if first.isEmpty { return second.count }
        if second.isEmpty { return first.count }

        let short: [Character]
        let long: [Character]
        if first.count <= second.count {
            short = first
            long = second
        } else {
            short = second
            long = first
        }

        var previous = Array(0...short.count)
        var current = [Int](repeating: 0, count: short.count + 1)
        for (longIndex, longCharacter) in long.enumerated() {
            current[0] = longIndex + 1
            for (shortIndex, shortCharacter) in short.enumerated() {
                let substitution = longCharacter == shortCharacter ? 0 : 1
                current[shortIndex + 1] = min(
                    previous[shortIndex + 1] + 1,
                    current[shortIndex] + 1,
                    previous[shortIndex] + substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[short.count]
    }
}

// MARK: - Session observations and immutable output
