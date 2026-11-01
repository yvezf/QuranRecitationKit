import Foundation
struct ExpectedTokenFrameProgress: Equatable, Sendable {
    let completedWordCount: Int
    let currentWordLocalIndex: Int?
    let currentWordFraction: Double
    let matchedTokenCount: Int
    let hasCurrentWordDivergence: Bool
    let divergentTokenID: Int?
    /// The CTC frame at which the last matched token of the prefix was first
    /// emitted (nil when nothing matched). When the whole line matched, this
    /// is where the line's last word ended in the window — the exact place
    /// the next line may begin.
    var matchedEndFrame: Int? = nil
    /// The number of CTC frames the window decoded to (for frame → sample).
    var frameCount: Int = 0

    var isCompleteLine: Bool {
        currentWordLocalIndex == nil && matchedTokenCount > 0
    }
}

/// Reduces greedy CTC frame winners to an exact canonical token prefix.
///
/// This intentionally does not use forced alignment: forced alignment can
/// place every requested token across arbitrary sufficiently long logits and
/// therefore cannot prove correctness. We collapse the actual greedy frames,
/// find the longest contiguous occurrence of the canonical prefix, and map its
/// exact token count through the catalog's frozen semantic-word boundaries.
enum ExpectedTokenFrameProgressAnalyzer {
    /// - Parameters:
    ///   - precedingTokenIDs: the token spelling of the word that ENDS the
    ///     line before this one. When the greedy stream still contains it
    ///     (the window reaches back into the previous line), this line's
    ///     prefix may only begin after its last occurrence — the next ayah
    ///     cannot start before the previous ayah's last word has ended.
    ///     sometimes auto highlight before i even say it" — the previous
    ///     line's tail ("…Allahu ahad", "…wa lam yulad") was being read as
    ///     the opening of the next ("Allahu s-samad", "wa lam yakun").
    static func analyze(
        frameTokenIDs: [Int],
        blankID: Int,
        expectedTokenIDs: [Int],
        wordTokenEnds: [Int],
        precedingTokenIDs: [Int] = [],
        precedingAlternateTokenIDs: [Int] = [],
        precedingFenceFrameLimit: Int? = nil,
        minimumStartFrame: Int? = nil
    ) -> ExpectedTokenFrameProgress? {
        guard blankID >= 0,
              !expectedTokenIDs.isEmpty,
              !wordTokenEnds.isEmpty,
              wordTokenEnds.last == expectedTokenIDs.count,
              zip(wordTokenEnds, wordTokenEnds.dropFirst()).allSatisfy({
                  $0.0 < $0.1
              }),
              wordTokenEnds[0] > 0 else {
            return nil
        }

        var greedyTokens: [Int] = []
        var greedyFrames: [Int] = []
        greedyTokens.reserveCapacity(frameTokenIDs.count)
        greedyFrames.reserveCapacity(frameTokenIDs.count)
        var previousFrameToken: Int?
        for (frame, tokenID) in frameTokenIDs.enumerated() {
            if tokenID != previousFrameToken, tokenID != blankID {
                greedyTokens.append(tokenID)
                greedyFrames.append(frame)
            }
            previousFrameToken = tokenID
        }

        // The earliest greedy index at which this line may begin: just after
        // the last occurrence of the previous line's final word, in either of
        // its spellings (the catalog's, and the audited alternate the model
        // actually emits for words like "ahad"), if present.
        // The fence only applies to the window's opening (the lead-in where
        // the previous line's tail can live): a line that itself repeats the
        // previous line's last word (Al-Fatiha's "الرحيم") must not fence
        // its own progress away.
        var earliestStart = 0
        for spelling in [precedingTokenIDs, precedingAlternateTokenIDs]
        where !spelling.isEmpty && greedyTokens.count >= spelling.count {
            var index = greedyTokens.count - spelling.count
            while index >= 0 {
                let endIndex = index + spelling.count
                let withinFence = precedingFenceFrameLimit.map {
                    greedyFrames[endIndex - 1] < $0
                } ?? true
                if withinFence,
                   Array(greedyTokens[index..<endIndex]) == spelling {
                    earliestStart = max(earliestStart, endIndex)
                    break
                }
                index -= 1
            }
        }

        if let minimumStartFrame {
            // The previous line's last token was emitted at a known frame:
            // this line cannot have begun before it.
            let firstAllowed = greedyFrames.firstIndex { $0 >= minimumStartFrame }
                ?? greedyTokens.count
            earliestStart = max(earliestStart, firstAllowed)
        }

        var bestStart: Int?
        var bestMatchCount = 0
        for start in greedyTokens.indices
        where start >= earliestStart && greedyTokens[start] == expectedTokenIDs[0] {
            var matched = 0
            while matched < expectedTokenIDs.count,
                  start + matched < greedyTokens.count,
                  greedyTokens[start + matched] == expectedTokenIDs[matched] {
                matched += 1
            }
            if matched > bestMatchCount || (matched == bestMatchCount && matched > 0) {
                bestStart = start
                bestMatchCount = matched
            }
        }

        let completedWordCount = wordTokenEnds.prefix {
            $0 <= bestMatchCount
        }.count
        let currentWordLocalIndex = completedWordCount < wordTokenEnds.count
            ? completedWordCount
            : nil
        var currentWordFraction: Double
        if let currentWordLocalIndex {
            let wordTokenStart = currentWordLocalIndex == 0
                ? 0
                : wordTokenEnds[currentWordLocalIndex - 1]
            let wordTokenEnd = wordTokenEnds[currentWordLocalIndex]
            currentWordFraction = Double(max(0, bestMatchCount - wordTokenStart))
                / Double(wordTokenEnd - wordTokenStart)
        } else {
            currentWordFraction = 0
        }
        // When the previous line's tail is still in this window (the fence
        // matched), a lone first token is more likely that tail or a breath
        // than the first word: the first word then needs two of its tokens
        // before it shows progress. With the window already clear of the
        // 2026-09-02: "milliseconds at most response time").
        if completedWordCount == 0,
           earliestStart > 0,
           bestMatchCount < min(2, wordTokenEnds[0]) {
            currentWordFraction = 0
        }

        let divergentTokenID: Int?
        if bestMatchCount >= expectedTokenIDs.count {
            divergentTokenID = nil
        } else if let bestStart {
            let divergentIndex = bestStart + bestMatchCount
            divergentTokenID = divergentIndex < greedyTokens.count
                ? greedyTokens[divergentIndex]
                : nil
        } else {
            divergentTokenID = greedyTokens.first
        }

        var matchedEndFrame: Int?
        if let bestStart, bestMatchCount > 0 {
            matchedEndFrame = greedyFrames[bestStart + bestMatchCount - 1]
        }

        return ExpectedTokenFrameProgress(
            completedWordCount: completedWordCount,
            currentWordLocalIndex: currentWordLocalIndex,
            currentWordFraction: min(
                max(currentWordFraction, 0),
                Double(1).nextDown
            ),
            matchedTokenCount: bestMatchCount,
            hasCurrentWordDivergence: divergentTokenID != nil,
            divergentTokenID: divergentTokenID,
            matchedEndFrame: matchedEndFrame,
            frameCount: frameTokenIDs.count
        )
    }
}

/// Bounded alternate token spellings for Quran words whose normalized catalogue
/// spelling can differ from the recognizer's correct SentencePiece output.
///
/// Al-Fatiha's صراط is the concrete affected case: the catalogue target is
/// `صرط`, while a correct live decode can be `صراط`. Both paths remain valid
/// for display progress and as acoustically equivalent expected targets. The
/// alternate is tightly scoped to the two audited Al-Fatiha locations.
///
/// Al-Ikhlas's أحد is the other audited case: the normalized catalogue
/// stores `احد` as `▁ا` + `حد`, while the model can emit its single
/// correct `▁أحد` token. That alternate is limited to 112:1 word 3 and
/// 112:4 word 4 (zero-based ayah word indices).
