import Foundation
enum QuranPronunciationTokenVariants {
    struct AlternateTokenization: Equatable, Sendable {
        let tokenIDs: [Int]
        let wordTokenEnds: [Int]
    }

    // Frozen   v0.2.0 vocabulary entries used by the model's
    // actual ordinary, unvocalized greedy spelling of `صراط`:
    // `▁ص` + `را` + `ط`. The previous implementation inserted the character
    // token `ا` into the catalogue spelling (`▁ص` + `ر` + `ط`), producing
    // `▁ص` + `ر` + `ا` + `ط` -- a sequence the shipped SentencePiece model
    // does not emit for this word. That synthetic sequence made the smoke pass
    // while live karaoke remained stuck on the first token.
    private static let siratWordStartTokenID = 117 // ▁ص
    private static let canonicalRaTokenID = 17 // ر
    private static let fusedRaAlefTokenID = 112 // را
    private static let siratWordEndTokenID = 40 // ط

    // Frozen   v0.2.0 vocabulary entries for أحد. Quran
    // normalization folds the hamzated alef, so the catalogue contains the
    // two-token `▁ا` + `حد` spelling even though the model can correctly
    // emit the vocabulary's single `▁أحد` token.
    private static let canonicalAhadStartTokenID = 49 // ▁ا
    private static let canonicalAhadEndTokenID = 154 // حد
    private static let fusedAhadTokenID = 371 // ▁أحد

    static func auditedAlternateTokenization(
        expectedTokenIDs: [Int],
        wordTokenEnds: [Int],
        surahNumber: Int,
        ayahNumber: Int,
        ayahWordRange: Range<Int>
    ) -> AlternateTokenization? {
        if surahNumber == 112 {
            return auditedAlIkhlasAhadTokenization(
                expectedTokenIDs: expectedTokenIDs,
                wordTokenEnds: wordTokenEnds,
                ayahNumber: ayahNumber,
                ayahWordRange: ayahWordRange
            )
        }

        guard surahNumber == 1,
              let ayahWordIndex = siratWordIndex(ayahNumber: ayahNumber),
              ayahWordRange.contains(ayahWordIndex) else {
            return nil
        }

        let localWordIndex = ayahWordIndex - ayahWordRange.lowerBound
        guard wordTokenEnds.indices.contains(localWordIndex) else {
            return nil
        }
        let wordStart = localWordIndex == 0
            ? 0
            : wordTokenEnds[localWordIndex - 1]
        let wordEnd = wordTokenEnds[localWordIndex]
        guard wordEnd - wordStart == 3,
              expectedTokenIDs.indices.contains(wordStart + 2),
              expectedTokenIDs[wordStart] == siratWordStartTokenID,
              expectedTokenIDs[wordStart + 1] == canonicalRaTokenID,
              expectedTokenIDs[wordStart + 2] == siratWordEndTokenID else {
            return nil
        }

        var alternateTokenIDs = expectedTokenIDs
        alternateTokenIDs[wordStart + 1] = fusedRaAlefTokenID
        return AlternateTokenization(
            tokenIDs: alternateTokenIDs,
            wordTokenEnds: wordTokenEnds
        )
    }

    private static func auditedAlIkhlasAhadTokenization(
        expectedTokenIDs: [Int],
        wordTokenEnds: [Int],
        ayahNumber: Int,
        ayahWordRange: Range<Int>
    ) -> AlternateTokenization? {
        guard let ayahWordIndex = ahadWordIndex(ayahNumber: ayahNumber),
              ayahWordRange.contains(ayahWordIndex),
              wordTokenEnds.count == ayahWordRange.count,
              wordTokenEnds.last == expectedTokenIDs.count else {
            return nil
        }

        let localWordIndex = ayahWordIndex - ayahWordRange.lowerBound
        guard wordTokenEnds.indices.contains(localWordIndex) else {
            return nil
        }
        let wordStart = localWordIndex == 0
            ? 0
            : wordTokenEnds[localWordIndex - 1]
        let wordEnd = wordTokenEnds[localWordIndex]
        guard wordEnd - wordStart == 2,
              expectedTokenIDs.indices.contains(wordStart + 1),
              expectedTokenIDs[wordStart] == canonicalAhadStartTokenID,
              expectedTokenIDs[wordStart + 1] == canonicalAhadEndTokenID else {
            return nil
        }

        var alternateTokenIDs = expectedTokenIDs
        alternateTokenIDs.replaceSubrange(
            wordStart..<wordEnd,
            with: [fusedAhadTokenID]
        )
        var alternateWordTokenEnds = wordTokenEnds
        for index in localWordIndex..<alternateWordTokenEnds.count {
            alternateWordTokenEnds[index] -= 1
        }
        return AlternateTokenization(
            tokenIDs: alternateTokenIDs,
            wordTokenEnds: alternateWordTokenEnds
        )
    }

    static func bestFrameProgress(
        canonical: ExpectedTokenFrameProgress?,
        frameTokenIDs: [Int],
        blankID: Int,
        expectedTokenIDs: [Int],
        wordTokenEnds: [Int],
        surahNumber: Int,
        ayahNumber: Int,
        ayahWordRange: Range<Int>,
        precedingTokenIDs: [Int] = [],
        precedingAlternateTokenIDs: [Int] = [],
        precedingFenceFrameLimit: Int? = nil,
        minimumStartFrame: Int? = nil
    ) -> ExpectedTokenFrameProgress? {
        guard let alternateTokenization = auditedAlternateTokenization(
            expectedTokenIDs: expectedTokenIDs,
            wordTokenEnds: wordTokenEnds,
            surahNumber: surahNumber,
            ayahNumber: ayahNumber,
            ayahWordRange: ayahWordRange
        ) else {
            return canonical
        }
        let alternate = ExpectedTokenFrameProgressAnalyzer.analyze(
            frameTokenIDs: frameTokenIDs,
            blankID: blankID,
            expectedTokenIDs: alternateTokenization.tokenIDs,
            wordTokenEnds: alternateTokenization.wordTokenEnds,
            precedingTokenIDs: precedingTokenIDs,
            precedingAlternateTokenIDs: precedingAlternateTokenIDs,
            precedingFenceFrameLimit: precedingFenceFrameLimit,
            minimumStartFrame: minimumStartFrame
        )
        return preferred(canonical, alternate)
    }

    private static func siratWordIndex(ayahNumber: Int) -> Int? {
        switch ayahNumber {
        case 6: 1 // اهدنا الصراط المستقيم
        case 7: 0 // صراط الذين ...
        default: nil
        }
    }

    private static func ahadWordIndex(ayahNumber: Int) -> Int? {
        switch ayahNumber {
        case 1: 3 // قل هو الله أحد
        case 4: 4 // ولم يكن له كفوا أحد
        default: nil
        }
    }

    private static func preferred(
        _ first: ExpectedTokenFrameProgress?,
        _ second: ExpectedTokenFrameProgress?
    ) -> ExpectedTokenFrameProgress? {
        guard let first else { return second }
        guard let second else { return first }
        if first.completedWordCount != second.completedWordCount {
            return first.completedWordCount > second.completedWordCount
                ? first
                : second
        }
        if first.currentWordFraction != second.currentWordFraction {
            return first.currentWordFraction > second.currentWordFraction
                ? first
                : second
        }
        return first.matchedTokenCount >= second.matchedTokenCount
            ? first
            : second
    }
}

/// Verifies that one ONNX window acoustically favors the selected Quran line.
///
/// The target and all confusers are scored from the same logits, so this adds
/// no model inference. Nearby and globally similar Quran lines come from the
/// deterministic  token catalog generated with the model tokenizer.
/// Decode alignment and sample-domain completion heuristics remain independent
/// gates in `LineAcceptancePolicy`.
