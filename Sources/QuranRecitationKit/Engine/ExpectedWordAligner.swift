import Foundation

struct ExpectedWordAlignment: Equatable, Sendable {
    /// Ayah-relative, zero-based expected-word indices supported by this
    /// decode. This is one inference snapshot, not cumulative session state.
    let matchedAyahWordIndices: Set<Int>

    /// Number of normalized recognized words considered. The recognized text
    /// itself is intentionally not retained or surfaced.
    let recognizedWordCount: Int
}

/// Chooses a real decoder-supported word for provisional  karaoke.
///
/// An empty or out-of-line snapshot intentionally returns `nil`. In particular,
/// silence and unrelated speech must never manufacture focus on the line's first
/// word merely because every valid line has a lower bound.
enum ProvisionalWordFocus {
    static func focusWordIndex(
        snapshotMatches: Set<Int>,
        lineWordRange: Range<Int>
    ) -> Int? {
        snapshotMatches.lazy.filter(lineWordRange.contains).max()
    }
}

/// Text-side word alignment mirrored from 's MIT tracker, narrowed to
/// the exact  line supplied by the app.
///
/// Matching is ordered and advances only forward through a five-word window.
/// It therefore cannot turn a bag of common Arabic words into arbitrary line
/// coverage. The separate acceptance policy remains the authority for growth.
enum ExpectedWordAligner {
    private static let lookaheadWords = 5
    private static let fuzzyThreshold = 0.70

    static func normalizedSemanticWords(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .compactMap { rawWord in
                let normalized = ArabicNormalizer.normalize(String(rawWord))
                let scalars = normalized.unicodeScalars.filter(isLetterOrNumber)
                let semanticWord = String(String.UnicodeScalarView(scalars))
                return semanticWord.isEmpty ? nil : semanticWord
            }
    }

    static func align(
        decodedText: String,
        expectedAyahWords: [String],
        lineWordRange: Range<Int>
    ) -> ExpectedWordAlignment {
        align(
            recognizedWords: normalizedSemanticWords(in: decodedText),
            expectedAyahWords: expectedAyahWords,
            lineWordRange: lineWordRange
        )
    }

    /// One inference may evaluate four canonical lines. Normalize its decode
    /// once, then reuse the same immutable words for every positional check.
    static func align(
        recognizedWords: [String],
        expectedAyahWords: [String],
        lineWordRange: Range<Int>
    ) -> ExpectedWordAlignment {
        guard lineWordRange.lowerBound >= 0,
              lineWordRange.upperBound <= expectedAyahWords.count,
              !lineWordRange.isEmpty else {
            return ExpectedWordAlignment(
                matchedAyahWordIndices: [],
                recognizedWordCount: 0
            )
        }

        guard !recognizedWords.isEmpty else {
            return ExpectedWordAlignment(
                matchedAyahWordIndices: [],
                recognizedWordCount: 0
            )
        }

        var matchedIndices = Set<Int>()
        var expectedPointer = lineWordRange.lowerBound

        for recognizedWord in recognizedWords {
            guard expectedPointer < lineWordRange.upperBound else { break }
            let limit = min(
                expectedPointer + lookaheadWords,
                lineWordRange.upperBound
            )

            for expectedIndex in expectedPointer..<limit {
                if wordsMatch(recognizedWord, expectedAyahWords[expectedIndex]) {
                    matchedIndices.insert(expectedIndex)
                    expectedPointer = expectedIndex + 1
                    break
                }
            }
        }

        return ExpectedWordAlignment(
            matchedAyahWordIndices: matchedIndices,
            recognizedWordCount: recognizedWords.count
        )
    }

    private static func wordsMatch(_ first: String, _ second: String) -> Bool {
        if first == second { return true }
        let firstCount = first.count
        let secondCount = second.count
        guard firstCount > 2, secondCount > 2 else { return false }
        return levenshteinRatio(first, second) >= fuzzyThreshold
    }

    /// Matches python-Levenshtein/'s ratio:
    /// `(len(a) + len(b) - distance) / (len(a) + len(b))`.
    private static func levenshteinRatio(_ first: String, _ second: String) -> Double {
        let firstCharacters = Array(first)
        let secondCharacters = Array(second)
        let lengthSum = firstCharacters.count + secondCharacters.count
        guard lengthSum > 0 else { return 1 }

        let distance = levenshteinDistance(firstCharacters, secondCharacters)
        return Double(lengthSum - distance) / Double(lengthSum)
    }

    private static func levenshteinDistance(
        _ first: [Character],
        _ second: [Character]
    ) -> Int {
        if first == second { return 0 }
        if first.isEmpty { return second.count }
        if second.isEmpty { return first.count }

        // The row allocation follows the shorter operand.
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
                let substitutionCost = longCharacter == shortCharacter ? 0 : 1
                current[shortIndex + 1] = min(
                    previous[shortIndex + 1] + 1,
                    current[shortIndex] + 1,
                    previous[shortIndex] + substitutionCost
                )
            }
            swap(&previous, &current)
        }

        return previous[short.count]
    }

    private static func isLetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
                .modifierLetter, .otherLetter,
                .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }
}
