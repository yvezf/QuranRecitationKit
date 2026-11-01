import Foundation

/// A numerically stable CTC forward score for one expected token sequence.
///
/// The acoustic model already emits log probabilities, so this scorer does not
/// perform another model pass.  uses it to compare the selected Quran
/// line with nearby/confusable lines from the exact same microphone window.
struct CTCSequenceScore: Equatable, Sendable {
    let logProbability: Double
    let logProbabilityPerFrame: Double
    let tokenCount: Int
    let timeStepCount: Int
}

/// The frames occupied by one expected token on the best valid CTC path.
///
/// `emissionFrameRange` is half-open. `representativeEmissionFrame` is the
/// highest-probability token frame inside that range, with the earliest frame
/// winning an exact tie. Keeping both lets callers use the full occupancy for
/// segment anchoring while using the representative frame for endpoint-tail
/// timing without treating a held CTC state as newly spoken audio.
struct CTCTokenEmissionAlignment: Equatable, Sendable {
    let tokenIndex: Int
    let tokenID: Int
    let emissionFrameRange: Range<Int>
    let representativeEmissionFrame: Int
}

/// A deterministic Viterbi alignment through the standard CTC topology.
struct CTCForcedAlignment: Equatable, Sendable {
    let viterbiLogProbability: Double
    let timeStepCount: Int
    let tokenAlignments: [CTCTokenEmissionAlignment]

    /// The representative emission frame for the final expected token.
    let terminalTokenEmissionFrame: Int
}

enum CTCScorerError: Error, Equatable, Sendable {
    case invalidTimeStepCount(Int)
    case invalidVocabularySize(Int)
    case invalidBlankID(Int)
    case outputElementCountMismatch(expected: Int, actual: Int)
    case tokenOutsideVocabulary(Int)
    case blankInsideTokenSequence
    case emptyTokenSequence
    case alignmentWorkspaceOverflow(timeSteps: Int, stateCount: Int)
    case unreachableAlignment(minimumTimeSteps: Int, actualTimeSteps: Int)
    case nonFiniteFrame(Int)
}

/// Scores a target with the standard CTC forward recursion.
///
/// Complexity is `O(timeSteps * tokenCount)` and memory is bounded to two
/// rows. This makes target-versus-confuser scoring cheap relative to the ONNX
/// forward pass and avoids copying the model's full output again.
struct CTCScorer: Sendable {
    let blankID: Int

    init(blankID: Int = 1_024) {
        self.blankID = blankID
    }

    func score(
        logProbabilities: [Float],
        timeSteps: Int,
        vocabularySize: Int,
        tokenIDs: [Int]
    ) throws -> CTCSequenceScore {
        guard timeSteps > 0 else {
            throw CTCScorerError.invalidTimeStepCount(timeSteps)
        }
        guard vocabularySize > 0 else {
            throw CTCScorerError.invalidVocabularySize(vocabularySize)
        }
        guard (0..<vocabularySize).contains(blankID) else {
            throw CTCScorerError.invalidBlankID(blankID)
        }

        let (expectedCount, overflowed) = timeSteps.multipliedReportingOverflow(
            by: vocabularySize
        )
        guard !overflowed, logProbabilities.count == expectedCount else {
            throw CTCScorerError.outputElementCountMismatch(
                expected: overflowed ? Int.max : expectedCount,
                actual: logProbabilities.count
            )
        }
        if let invalid = tokenIDs.first(where: { !(0..<vocabularySize).contains($0) }) {
            throw CTCScorerError.tokenOutsideVocabulary(invalid)
        }
        guard !tokenIDs.contains(blankID) else {
            throw CTCScorerError.blankInsideTokenSequence
        }

        // blank, token, blank, token, ... blank. An empty target therefore
        // has exactly one state and scores the all-blank CTC path. 
        // includes that path among the proper incompletion candidates for
        // every expected line, alongside all nonempty strict token prefixes.
        let stateCount = tokenIDs.count * 2 + 1
        var previous = Array(repeating: -Double.infinity, count: stateCount)
        var current = previous

        previous[0] = try value(
            atTimeStep: 0,
            tokenID: blankID,
            logProbabilities: logProbabilities,
            vocabularySize: vocabularySize
        )
        if stateCount > 1 {
            previous[1] = try value(
                atTimeStep: 0,
                tokenID: tokenIDs[0],
                logProbabilities: logProbabilities,
                vocabularySize: vocabularySize
            )
        }

        if timeSteps > 1 {
            for timeStep in 1..<timeSteps {
                for state in current.indices {
                    current[state] = -Double.infinity
                }

                for state in 0..<stateCount {
                    let emittedToken = token(atState: state, tokenIDs: tokenIDs)
                    var predecessor = previous[state]
                    if state > 0 {
                        predecessor = logAdd(predecessor, previous[state - 1])
                    }
                    if state > 1,
                       emittedToken != blankID,
                       emittedToken != token(atState: state - 2, tokenIDs: tokenIDs) {
                        predecessor = logAdd(predecessor, previous[state - 2])
                    }

                    let emission = try value(
                        atTimeStep: timeStep,
                        tokenID: emittedToken,
                        logProbabilities: logProbabilities,
                        vocabularySize: vocabularySize
                    )
                    current[state] = predecessor + emission
                }
                swap(&previous, &current)
            }
        }

        let terminal = stateCount == 1
            ? previous[0]
            : logAdd(previous[stateCount - 1], previous[stateCount - 2])
        guard terminal.isFinite else {
            throw CTCScorerError.nonFiniteFrame(timeSteps - 1)
        }

        return CTCSequenceScore(
            logProbability: terminal,
            logProbabilityPerFrame: terminal / Double(timeSteps),
            tokenCount: tokenIDs.count,
            timeStepCount: timeSteps
        )
    }

    /// Finds the single highest-probability CTC path for a nonempty expected
    /// token sequence and returns its per-token emission frames.
    ///
    /// The transition topology exactly matches `score`: a state can stay,
    /// advance by one, or skip an intervening blank only when the current token
    /// is not a repeat of the previous token. Exact score ties prefer staying,
    /// then a one-state advance, then a two-state skip. The terminal blank wins
    /// a terminal-state tie. Together those rules deterministically place
    /// equivalent emissions as early as the acoustic scores allow.
    ///
    /// Score memory is `O(tokenCount)`. Traceback uses one byte per
    /// `(timeStep - 1, CTC state)` instead of retaining the dynamic-programming
    /// score matrix.
    func forcedAlignment(
        logProbabilities: [Float],
        timeSteps: Int,
        vocabularySize: Int,
        tokenIDs: [Int]
    ) throws -> CTCForcedAlignment {
        guard timeSteps > 0 else {
            throw CTCScorerError.invalidTimeStepCount(timeSteps)
        }
        guard vocabularySize > 0 else {
            throw CTCScorerError.invalidVocabularySize(vocabularySize)
        }
        guard (0..<vocabularySize).contains(blankID) else {
            throw CTCScorerError.invalidBlankID(blankID)
        }

        let (expectedCount, outputCountOverflowed) = timeSteps.multipliedReportingOverflow(
            by: vocabularySize
        )
        guard !outputCountOverflowed, logProbabilities.count == expectedCount else {
            throw CTCScorerError.outputElementCountMismatch(
                expected: outputCountOverflowed ? Int.max : expectedCount,
                actual: logProbabilities.count
            )
        }
        if let invalid = tokenIDs.first(where: { !(0..<vocabularySize).contains($0) }) {
            throw CTCScorerError.tokenOutsideVocabulary(invalid)
        }
        guard !tokenIDs.contains(blankID) else {
            throw CTCScorerError.blankInsideTokenSequence
        }
        guard !tokenIDs.isEmpty else {
            throw CTCScorerError.emptyTokenSequence
        }

        let adjacentRepeatCount = zip(tokenIDs, tokenIDs.dropFirst()).reduce(into: 0) {
            count, pair in
            if pair.0 == pair.1 { count += 1 }
        }
        let (minimumTimeSteps, minimumOverflowed) = tokenIDs.count.addingReportingOverflow(
            adjacentRepeatCount
        )
        guard !minimumOverflowed, timeSteps >= minimumTimeSteps else {
            throw CTCScorerError.unreachableAlignment(
                minimumTimeSteps: minimumOverflowed ? Int.max : minimumTimeSteps,
                actualTimeSteps: timeSteps
            )
        }

        let (doubledTokenCount, stateCountOverflowed) = tokenIDs.count
            .multipliedReportingOverflow(by: 2)
        let (stateCount, finalStateCountOverflowed) = doubledTokenCount
            .addingReportingOverflow(1)
        guard !stateCountOverflowed, !finalStateCountOverflowed else {
            throw CTCScorerError.alignmentWorkspaceOverflow(
                timeSteps: timeSteps,
                stateCount: Int.max
            )
        }

        let tracebackTimeSteps = timeSteps - 1
        let (tracebackCount, tracebackOverflowed) = tracebackTimeSteps
            .multipliedReportingOverflow(by: stateCount)
        guard !tracebackOverflowed else {
            throw CTCScorerError.alignmentWorkspaceOverflow(
                timeSteps: timeSteps,
                stateCount: stateCount
            )
        }

        // 0 = stayed in state, 1 = advanced one state, 2 = skipped a blank.
        // UInt8.max marks an unreachable state and also makes corrupt
        // traceback state fail closed instead of indexing an arbitrary path.
        let unreachablePredecessor = UInt8.max
        var predecessors = Array(
            repeating: unreachablePredecessor,
            count: tracebackCount
        )
        var previous = Array(repeating: -Double.infinity, count: stateCount)
        var current = previous

        previous[0] = try value(
            atTimeStep: 0,
            tokenID: blankID,
            logProbabilities: logProbabilities,
            vocabularySize: vocabularySize
        )
        previous[1] = try value(
            atTimeStep: 0,
            tokenID: tokenIDs[0],
            logProbabilities: logProbabilities,
            vocabularySize: vocabularySize
        )

        if timeSteps > 1 {
            for timeStep in 1..<timeSteps {
                for state in current.indices {
                    current[state] = -Double.infinity
                }

                let tracebackOffset = (timeStep - 1) * stateCount
                for state in 0..<stateCount {
                    let emittedToken = token(atState: state, tokenIDs: tokenIDs)

                    // Candidate order is the documented deterministic tie
                    // order. Updating only for a strictly higher score keeps
                    // the earlier candidate when values are equal.
                    var predecessorScore = previous[state]
                    var predecessorDelta: UInt8 = predecessorScore.isFinite
                        ? 0
                        : unreachablePredecessor
                    if state > 0, previous[state - 1] > predecessorScore {
                        predecessorScore = previous[state - 1]
                        predecessorDelta = 1
                    }
                    if state > 1,
                       emittedToken != blankID,
                       emittedToken != token(atState: state - 2, tokenIDs: tokenIDs),
                       previous[state - 2] > predecessorScore {
                        predecessorScore = previous[state - 2]
                        predecessorDelta = 2
                    }

                    // Match `score`'s finite-value validation even for a CTC
                    // state that is not reachable at this particular frame.
                    let emission = try value(
                        atTimeStep: timeStep,
                        tokenID: emittedToken,
                        logProbabilities: logProbabilities,
                        vocabularySize: vocabularySize
                    )
                    if predecessorScore.isFinite {
                        current[state] = predecessorScore + emission
                        predecessors[tracebackOffset + state] = predecessorDelta
                    }
                }
                swap(&previous, &current)
            }
        }

        let finalTokenState = stateCount - 2
        let finalBlankState = stateCount - 1
        let terminalState: Int
        let terminalScore: Double
        if previous[finalBlankState] >= previous[finalTokenState] {
            terminalState = finalBlankState
            terminalScore = previous[finalBlankState]
        } else {
            terminalState = finalTokenState
            terminalScore = previous[finalTokenState]
        }
        guard terminalScore.isFinite else {
            throw CTCScorerError.unreachableAlignment(
                minimumTimeSteps: minimumTimeSteps,
                actualTimeSteps: timeSteps
            )
        }

        var firstEmissionFrames = Array(repeating: -1, count: tokenIDs.count)
        var lastEmissionFrames = firstEmissionFrames
        var representativeFrames = firstEmissionFrames
        var representativeScores = Array(
            repeating: -Double.infinity,
            count: tokenIDs.count
        )

        // Aggregate spans directly while tracing backward; there is no need
        // to allocate another array proportional to the audio duration.
        var state = terminalState
        for timeStep in stride(from: timeSteps - 1, through: 0, by: -1) {
            if !state.isMultiple(of: 2) {
                let tokenIndex = state / 2
                firstEmissionFrames[tokenIndex] = timeStep
                if lastEmissionFrames[tokenIndex] < 0 {
                    lastEmissionFrames[tokenIndex] = timeStep
                }

                let emission = try value(
                    atTimeStep: timeStep,
                    tokenID: tokenIDs[tokenIndex],
                    logProbabilities: logProbabilities,
                    vocabularySize: vocabularySize
                )
                if emission > representativeScores[tokenIndex]
                    || (emission == representativeScores[tokenIndex]
                        && timeStep < representativeFrames[tokenIndex]) {
                    representativeScores[tokenIndex] = emission
                    representativeFrames[tokenIndex] = timeStep
                }
            }

            if timeStep > 0 {
                let predecessor = predecessors[(timeStep - 1) * stateCount + state]
                guard predecessor != unreachablePredecessor, Int(predecessor) <= state else {
                    throw CTCScorerError.unreachableAlignment(
                        minimumTimeSteps: minimumTimeSteps,
                        actualTimeSteps: timeSteps
                    )
                }
                state -= Int(predecessor)
            }
        }

        var tokenAlignments: [CTCTokenEmissionAlignment] = []
        tokenAlignments.reserveCapacity(tokenIDs.count)
        for tokenIndex in tokenIDs.indices {
            let firstFrame = firstEmissionFrames[tokenIndex]
            let lastFrame = lastEmissionFrames[tokenIndex]
            let representativeFrame = representativeFrames[tokenIndex]
            guard firstFrame >= 0, lastFrame >= firstFrame, representativeFrame >= firstFrame else {
                throw CTCScorerError.unreachableAlignment(
                    minimumTimeSteps: minimumTimeSteps,
                    actualTimeSteps: timeSteps
                )
            }
            tokenAlignments.append(CTCTokenEmissionAlignment(
                tokenIndex: tokenIndex,
                tokenID: tokenIDs[tokenIndex],
                emissionFrameRange: firstFrame..<(lastFrame + 1),
                representativeEmissionFrame: representativeFrame
            ))
        }

        guard let terminalTokenEmissionFrame = tokenAlignments.last?
            .representativeEmissionFrame else {
            throw CTCScorerError.emptyTokenSequence
        }
        return CTCForcedAlignment(
            viterbiLogProbability: terminalScore,
            timeStepCount: timeSteps,
            tokenAlignments: tokenAlignments,
            terminalTokenEmissionFrame: terminalTokenEmissionFrame
        )
    }

    private func token(atState state: Int, tokenIDs: [Int]) -> Int {
        state.isMultiple(of: 2) ? blankID : tokenIDs[state / 2]
    }

    private func value(
        atTimeStep timeStep: Int,
        tokenID: Int,
        logProbabilities: [Float],
        vocabularySize: Int
    ) throws -> Double {
        let result = Double(logProbabilities[timeStep * vocabularySize + tokenID])
        guard result.isFinite else {
            throw CTCScorerError.nonFiniteFrame(timeStep)
        }
        return result
    }

    private func logAdd(_ lhs: Double, _ rhs: Double) -> Double {
        if lhs == -.infinity { return rhs }
        if rhs == -.infinity { return lhs }
        let maximum = max(lhs, rhs)
        return maximum + log1p(exp(min(lhs, rhs) - maximum))
    }
}
