import Foundation

struct CTCDecodeResult: Equatable, Sendable {
    /// Normalized text after SentencePiece word-boundary expansion.
    let text: String

    /// Greedy CTC token IDs after repeat collapse and blank removal.
    let tokenIDs: [Int]

    /// The argmax token ID selected at every model time step.
    let frameTokenIDs: [Int]
}

enum CTCDecoderError: Error, Equatable, Sendable {
    case invalidBlankID(Int)
    case invalidTimeStepCount(Int)
    case invalidVocabularySize(Int)
    case blankOutsideModelVocabulary(blankID: Int, vocabularySize: Int)
    case outputElementCountMismatch(expected: Int, actual: Int)
    case frameContainsOnlyNaN(Int)
    case negativeTokenID(Int)
}

/// Greedy CTC decoding for the text/BPE  model family.
///
/// This type performs no inference and has no dependency on ONNX Runtime. A
/// future model adapter supplies row-major `[timeSteps, vocabularySize]` logits
/// or log-probabilities and an explicit output shape.
struct GreedyCTCDecoder: Sendable {
    private static let sentencePieceWordPrefix = "\u{2581}"

    private let vocabulary: [Int: String]
    let blankID: Int

    init(vocabulary: [Int: String], blankID: Int? = nil) throws {
        let resolvedBlankID = blankID ?? vocabulary.keys.max() ?? -1
        guard resolvedBlankID >= 0 else {
            throw CTCDecoderError.invalidBlankID(resolvedBlankID)
        }
        guard vocabulary.keys.allSatisfy({ $0 >= 0 }) else {
            throw CTCDecoderError.negativeTokenID(
                vocabulary.keys.first(where: { $0 < 0 }) ?? -1
            )
        }

        self.vocabulary = vocabulary
        self.blankID = resolvedBlankID
    }

    func decode(
        logProbabilities: [Float],
        timeSteps: Int,
        vocabularySize: Int
    ) throws -> CTCDecodeResult {
        guard timeSteps >= 0 else {
            throw CTCDecoderError.invalidTimeStepCount(timeSteps)
        }
        guard vocabularySize > 0 else {
            throw CTCDecoderError.invalidVocabularySize(vocabularySize)
        }
        guard blankID < vocabularySize else {
            throw CTCDecoderError.blankOutsideModelVocabulary(
                blankID: blankID,
                vocabularySize: vocabularySize
            )
        }

        let (expectedCount, overflowed) = timeSteps.multipliedReportingOverflow(by: vocabularySize)
        guard !overflowed, logProbabilities.count == expectedCount else {
            throw CTCDecoderError.outputElementCountMismatch(
                expected: overflowed ? Int.max : expectedCount,
                actual: logProbabilities.count
            )
        }

        var frameTokenIDs: [Int] = []
        frameTokenIDs.reserveCapacity(timeSteps)

        for timeStep in 0..<timeSteps {
            let offset = timeStep * vocabularySize
            var bestIndex: Int?
            var bestValue = -Float.infinity

            for tokenIndex in 0..<vocabularySize {
                let value = logProbabilities[offset + tokenIndex]
                guard !value.isNaN else { continue }
                if bestIndex == nil || value > bestValue {
                    bestIndex = tokenIndex
                    bestValue = value
                }
            }

            guard let bestIndex else {
                throw CTCDecoderError.frameContainsOnlyNaN(timeStep)
            }
            frameTokenIDs.append(bestIndex)
        }

        return try decode(frameTokenIDs: frameTokenIDs)
    }

    func decode(frameTokenIDs: [Int]) throws -> CTCDecodeResult {
        if let invalidID = frameTokenIDs.first(where: { $0 < 0 }) {
            throw CTCDecoderError.negativeTokenID(invalidID)
        }

        var collapsedTokenIDs: [Int] = []
        collapsedTokenIDs.reserveCapacity(frameTokenIDs.count)
        var previousID: Int?

        for tokenID in frameTokenIDs {
            if tokenID != previousID, tokenID != blankID {
                collapsedTokenIDs.append(tokenID)
            }
            previousID = tokenID
        }

        return CTCDecodeResult(
            text: tokenIDsToText(collapsedTokenIDs),
            tokenIDs: collapsedTokenIDs,
            frameTokenIDs: frameTokenIDs
        )
    }

    func tokenIDsToText(_ tokenIDs: [Int]) -> String {
        let joined = tokenIDs.compactMap { tokenID -> String? in
            guard tokenID != blankID, let token = vocabulary[tokenID] else { return nil }
            guard !token.isEmpty, token != "<unk>", token != "<blank>" else { return nil }
            return token
        }
        .joined()
        .replacingOccurrences(of: Self.sentencePieceWordPrefix, with: " ")

        return ArabicNormalizer.normalize(joined)
    }
}
