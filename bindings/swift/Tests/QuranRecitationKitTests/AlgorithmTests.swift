import XCTest
@testable import QuranRecitationKit
final class AlgorithmTests: XCTestCase {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    func testArabicNormalization() throws {
        let source = "\u{FEFF}أَلْـرَّحْمَٰنُ  إِلَى\tرَحْمَةٍ"
        try expect(
            ArabicNormalizer.normalize(source) == "الرحمن الي رحمه",
            "Arabic normalizer did not mirror the expected  folding"
        )
    }

    func testGreedyCTCCollapse() throws {
        let decoder = try GreedyCTCDecoder(
            vocabulary: [
                0: "\u{2581}qa",
                1: "l",
                2: "<blank>",
                3: "<unk>"
            ],
            blankID: 2
        )

        // Frame winners: 0, 0, blank, 0, 1. Adjacent 0 collapses, while the
        // blank separates the later 0 so the result is [0, 0, 1].
        let frameWinners = [0, 0, 2, 0, 1]
        var logits = Array(repeating: Float(-100), count: frameWinners.count * 4)
        for (timeStep, winner) in frameWinners.enumerated() {
            logits[timeStep * 4 + winner] = 0
        }

        let result = try decoder.decode(
            logProbabilities: logits,
            timeSteps: frameWinners.count,
            vocabularySize: 4
        )
        try expect(result.tokenIDs == [0, 0, 1], "CTC repeat/blank collapse was incorrect")
        try expect(result.text == "qa qal", "SentencePiece text expansion was incorrect")
    }

    func testCTCForwardScoreRanksExpectedSequence() throws {
        // Frames strongly emit token 0, blank, then token 1. The expected
        // sequence [0, 1] must outrank the reversed confuser [1, 0].
        let vocabularySize = 3
        let blankID = 2
        let winners = [0, 0, blankID, 1, 1]
        var logProbabilities = Array(
            repeating: Float(-12),
            count: winners.count * vocabularySize
        )
        for (frame, winner) in winners.enumerated() {
            logProbabilities[frame * vocabularySize + winner] = -0.01
        }

        let scorer = CTCScorer(blankID: blankID)
        let expected = try scorer.score(
            logProbabilities: logProbabilities,
            timeSteps: winners.count,
            vocabularySize: vocabularySize,
            tokenIDs: [0, 1]
        )
        let confuser = try scorer.score(
            logProbabilities: logProbabilities,
            timeSteps: winners.count,
            vocabularySize: vocabularySize,
            tokenIDs: [1, 0]
        )
        try expect(
            expected.logProbability > confuser.logProbability,
            "CTC scorer did not rank the emitted token order first"
        )
    }

    func testCTCBlankOnlyScore() throws {
        let vocabularySize = 2
        let blankID = 1
        let blankValues: [Float] = [-0.30, -0.20, -0.40]
        var logProbabilities: [Float] = []
        for blankValue in blankValues {
            logProbabilities.append(-1.5)
            logProbabilities.append(blankValue)
        }

        let score = try CTCScorer(blankID: blankID).score(
            logProbabilities: logProbabilities,
            timeSteps: blankValues.count,
            vocabularySize: vocabularySize,
            tokenIDs: []
        )
        let expected = blankValues.reduce(0) { $0 + Double($1) }
        try expect(score.tokenCount == 0, "Blank-only CTC score reported a token")
        try expect(
            abs(score.logProbability - expected) < 0.000_001,
            "Blank-only CTC score was not the exact all-blank path"
        )
        try expect(
            abs(score.logProbabilityPerFrame - expected / Double(blankValues.count))
                < 0.000_001,
            "Blank-only per-frame CTC score was incorrect"
        )
    }

    func testCTCForcedAlignmentSeparatesRepeatedTokens() throws {
        let vocabularySize = 3
        let blankID = 2
        let winners = [0, 0, blankID, 0, 0, blankID]
        var logProbabilities = Array(
            repeating: Float(-12),
            count: winners.count * vocabularySize
        )
        for (frame, winner) in winners.enumerated() {
            logProbabilities[frame * vocabularySize + winner] = -0.01
        }

        let scorer = CTCScorer(blankID: blankID)
        let scoreBeforeAlignment = try scorer.score(
            logProbabilities: logProbabilities,
            timeSteps: winners.count,
            vocabularySize: vocabularySize,
            tokenIDs: [0, 0]
        )
        let alignment = try scorer.forcedAlignment(
            logProbabilities: logProbabilities,
            timeSteps: winners.count,
            vocabularySize: vocabularySize,
            tokenIDs: [0, 0]
        )
        let scoreAfterAlignment = try scorer.score(
            logProbabilities: logProbabilities,
            timeSteps: winners.count,
            vocabularySize: vocabularySize,
            tokenIDs: [0, 0]
        )

        try expect(
            scoreBeforeAlignment == scoreAfterAlignment,
            "Forced alignment changed the forward-score path"
        )
        try expect(alignment.tokenAlignments.count == 2, "Repeated token was not aligned twice")
        let first = alignment.tokenAlignments[0]
        let second = alignment.tokenAlignments[1]
        try expect(first.tokenIndex == 0 && first.tokenID == 0, "First token identity was incorrect")
        try expect(second.tokenIndex == 1 && second.tokenID == 0, "Repeated token identity was incorrect")
        try expect(first.emissionFrameRange == 0..<2, "First repeated-token span was incorrect")
        try expect(second.emissionFrameRange == 3..<5, "Second repeated-token span was incorrect")
        try expect(
            first.emissionFrameRange.upperBound < second.emissionFrameRange.lowerBound,
            "Repeated tokens were not separated by the mandatory CTC blank"
        )
        try expect(
            alignment.tokenAlignments.map(\.representativeEmissionFrame) == [0, 3],
            "Representative emission frames were not deterministic and ordered"
        )
        try expect(
            alignment.terminalTokenEmissionFrame == 3,
            "Terminal token did not expose its representative emission frame"
        )
        try expect(
            alignment.viterbiLogProbability <= scoreBeforeAlignment.logProbability,
            "Viterbi path exceeded the summed CTC forward probability"
        )
    }

    func testCTCForcedAlignmentRejectsMalformedInput() throws {
        let scorer = CTCScorer(blankID: 2)
        let validLogProbabilities = Array(repeating: Float(-1), count: 2 * 3)

        try expectCTCError(.emptyTokenSequence) {
            _ = try scorer.forcedAlignment(
                logProbabilities: validLogProbabilities,
                timeSteps: 2,
                vocabularySize: 3,
                tokenIDs: []
            )
        }
        try expectCTCError(.outputElementCountMismatch(expected: 6, actual: 5)) {
            _ = try scorer.forcedAlignment(
                logProbabilities: Array(validLogProbabilities.dropLast()),
                timeSteps: 2,
                vocabularySize: 3,
                tokenIDs: [0]
            )
        }
        try expectCTCError(.blankInsideTokenSequence) {
            _ = try scorer.forcedAlignment(
                logProbabilities: validLogProbabilities,
                timeSteps: 2,
                vocabularySize: 3,
                tokenIDs: [2]
            )
        }
        try expectCTCError(.unreachableAlignment(minimumTimeSteps: 3, actualTimeSteps: 2)) {
            _ = try scorer.forcedAlignment(
                logProbabilities: validLogProbabilities,
                timeSteps: 2,
                vocabularySize: 3,
                tokenIDs: [0, 0]
            )
        }

        var nonFinite = validLogProbabilities
        nonFinite[3] = .nan
        try expectCTCError(.nonFiniteFrame(1)) {
            _ = try scorer.forcedAlignment(
                logProbabilities: nonFinite,
                timeSteps: 2,
                vocabularySize: 3,
                tokenIDs: [0]
            )
        }
    }

    func testOneBasedConversionAndNonCumulativeUnion() throws {
        let sessionID = fixedSessionID
        var matcher = ExpectedLineMatcher(
            request: try makeRequest(sessionID: sessionID, range: 0..<4, totalWords: 4)
        )

        let first = matcher.consume(observation(
            sessionID: sessionID,
            sequence: 1,
            wordIndexOneBased: 1,
            totalWords: 4,
            matched: [0]
        ))
        guard case let .accepted(firstProgress) = first else {
            throw Failure(description: "First valid word observation was rejected")
        }
        try expect(firstProgress.focusWordIndex == 0, "One-based focus was not converted to zero-based")
        try expect(firstProgress.matchedLineWordCount == 1, "First word did not advance the prefix")

        let second = matcher.consume(observation(
            sessionID: sessionID,
            sequence: 2,
            wordIndexOneBased: 2,
            totalWords: 4,
            matched: [1]
        ))
        guard case let .accepted(secondProgress) = second else {
            throw Failure(description: "Second non-cumulative observation was rejected")
        }
        try expect(
            secondProgress.cumulativeMatchedWordIndices == Set([0, 1]),
            "Non-cumulative matched indices were not unioned"
        )
        try expect(secondProgress.matchedLineWordCount == 2, "Cumulative prefix count was incorrect")
    }

    func testDuplicateStaleAndWrongVerseRejection() throws {
        let sessionID = fixedSessionID
        var matcher = ExpectedLineMatcher(
            request: try makeRequest(sessionID: sessionID, range: 0..<3, totalWords: 3)
        )

        let wrongSession = matcher.consume(observation(
            sessionID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            sequence: 99,
            wordIndexOneBased: 1,
            totalWords: 3,
            matched: [0]
        ))
        try expect(
            wrongSession == .ignored(.differentSession),
            "A different recognition session advanced progress"
        )
        try expect(matcher.lastSeenSequence == nil, "A foreign session contaminated sequence state")

        _ = matcher.consume(observation(
            sessionID: sessionID,
            sequence: 1,
            wordIndexOneBased: 1,
            totalWords: 3,
            matched: [0]
        ))

        let duplicateSequence = matcher.consume(observation(
            sessionID: sessionID,
            sequence: 1,
            wordIndexOneBased: 2,
            totalWords: 3,
            matched: [1]
        ))
        try expect(
            duplicateSequence == .ignored(.staleOrDuplicateSequence),
            "Duplicate sequence advanced progress"
        )

        let duplicateEvidence = matcher.consume(observation(
            sessionID: sessionID,
            sequence: 2,
            wordIndexOneBased: 1,
            totalWords: 3,
            matched: [0]
        ))
        try expect(
            duplicateEvidence == .ignored(.noNewEvidence),
            "Duplicate evidence was emitted twice"
        )

        let wrongVerse = matcher.consume(InternalWordProgressObservation(
            sessionID: sessionID,
            sequence: 3,
            surahNumber: 112,
            ayahNumber: 2,
            wordIndexOneBased: 2,
            totalWords: 3,
            matchedWordIndices: [1]
        ))
        try expect(wrongVerse == .ignored(.wrongVerse), "Wrong ayah advanced progress")
        try expect(matcher.cumulativeMatchedWordIndices == Set([0]), "Rejected data contaminated state")

        let staleAfterWrongVerse = matcher.consume(observation(
            sessionID: sessionID,
            sequence: 2,
            wordIndexOneBased: 2,
            totalWords: 3,
            matched: [1]
        ))
        try expect(
            staleAfterWrongVerse == .ignored(.staleOrDuplicateSequence),
            "An older event was accepted after a newer same-session event"
        )
    }

    func testGapDoesNotAdvancePrefix() throws {
        let sessionID = fixedSessionID
        var matcher = ExpectedLineMatcher(
            request: try makeRequest(sessionID: sessionID, range: 0..<3, totalWords: 3)
        )

        let gapped = matcher.consume(observation(
            sessionID: sessionID,
            sequence: 1,
            wordIndexOneBased: 3,
            totalWords: 3,
            matched: [0, 2]
        ))
        guard case let .accepted(gappedProgress) = gapped else {
            throw Failure(description: "Gapped evidence was rejected instead of safely retained")
        }
        try expect(gappedProgress.matchedLineWordCount == 1, "A gap incorrectly counted as contiguous")
        try expect(!gappedProgress.isLineReady, "A gapped line was marked ready")

        let gapFilled = matcher.consume(observation(
            sessionID: sessionID,
            sequence: 2,
            wordIndexOneBased: 2,
            totalWords: 3,
            matched: [1]
        ))
        guard case let .accepted(completedProgress) = gapFilled else {
            throw Failure(description: "Gap-closing evidence was rejected")
        }
        try expect(completedProgress.matchedLineWordCount == 3, "Filled cumulative prefix was incorrect")
        try expect(completedProgress.isLineReady, "Complete contiguous line was not marked ready")
    }

    func testSameAyahLaterLineRange() throws {
        let sessionID = fixedSessionID
        var matcher = ExpectedLineMatcher(
            request: try makeRequest(sessionID: sessionID, range: 3..<6, totalWords: 6)
        )

        let first = matcher.consume(observation(
            sessionID: sessionID,
            sequence: 1,
            wordIndexOneBased: 4,
            totalWords: 6,
            matched: [0, 1, 2, 3]
        ))
        guard case let .accepted(firstProgress) = first else {
            throw Failure(description: "First word of a later same-ayah line was rejected")
        }
        try expect(
            firstProgress.cumulativeMatchedWordIndices == Set([3]),
            "Words from an earlier display line leaked into the active line"
        )

        let outOfOrderTail = matcher.consume(observation(
            sessionID: sessionID,
            sequence: 2,
            wordIndexOneBased: 6,
            totalWords: 6,
            matched: [5]
        ))
        guard case let .accepted(tailProgress) = outOfOrderTail else {
            throw Failure(description: "Later-line tail evidence was rejected")
        }
        try expect(tailProgress.matchedLineWordCount == 1, "Tail evidence crossed a missing word")

        let complete = matcher.consume(observation(
            sessionID: sessionID,
            sequence: 3,
            wordIndexOneBased: 5,
            totalWords: 6,
            matched: [4]
        ))
        guard case let .accepted(finalProgress) = complete else {
            throw Failure(description: "Same-ayah line gap-closing evidence was rejected")
        }
        try expect(finalProgress.isLineReady, "Later same-ayah line did not become ready")
    }

    func testProvisionalEvidenceNeverAccepts() throws {
        let range = 0..<2
        let matches = Set(range)
        var policy = LineAcceptancePolicy(lineWordRange: range)

        for sequence in 1...5 {
            let evidence = policy.evaluate(
                progress: policyProgress(
                    range: range,
                    matches: matches,
                    sequence: UInt64(sequence)
                ),
                matchedLineWordIndices: matches,
                sequence: UInt64(sequence),
                isFreshCycle: true,
                freshSampleCount: 3_200,
                speechSpanSampleCount: 16_800,
                trailingSilenceSampleCount: 6_400,
                lastVoiceOutputSample: 20_000,
                acousticDecision: sequence.isMultiple(of: 2) ? .rejected : .inconclusive
            )
            try expect(!evidence.isAccepted, "Non-identity evidence accepted a line")
            try expect(
                evidence.acceptedWordCount == 0,
                "Non-identity evidence awarded growth"
            )
            try expect(
                !evidence.isIdentityMatchedPartial,
                "Non-identity evidence was marked as an identity match"
            )
        }
    }

    func testHeuristicSampleAndCurrentSnapshotBoundaries() throws {
        let range = 0..<4
        let complete = Set(range)

        func oneCycle(
            freshSamples: Int = 3_200,
            speechSamples: Int = 13_600,
            silenceSamples: Int = 6_400,
            currentMatches: Set<Int> = complete
        ) -> LineEvidence {
            var policy = LineAcceptancePolicy(lineWordRange: range)
            return policy.evaluate(
                progress: policyProgress(range: range, matches: complete, sequence: 1),
                matchedLineWordIndices: currentMatches,
                sequence: 1,
                isFreshCycle: true,
                freshSampleCount: freshSamples,
                speechSpanSampleCount: speechSamples,
                trailingSilenceSampleCount: silenceSamples,
                lastVoiceOutputSample: 50_000,
                acousticDecision: .identityMatched
            )
        }

        try expect(oneCycle(freshSamples: 3_199).stableCycleCount == 0, "3,199 fresh samples qualified")
        try expect(oneCycle(freshSamples: 3_200).stableCycleCount == 1, "3,200 fresh samples did not qualify")
        try expect(oneCycle(speechSamples: 13_599).stableCycleCount == 0, "Sub-floor speech span qualified")
        try expect(oneCycle(speechSamples: 13_600).stableCycleCount == 1, "Exact speech-span floor failed")
        try expect(oneCycle(silenceSamples: 6_399).stableCycleCount == 0, "6,399 silence samples qualified")
        try expect(oneCycle(silenceSamples: 6_400).stableCycleCount == 1, "6,400 silence samples failed")
        try expect(oneCycle(silenceSamples: 12_800).stableCycleCount == 1, "12,800 silence samples failed")
        try expect(oneCycle(silenceSamples: 19_200).stableCycleCount == 1, "19,200 silence samples failed")
        try expect(oneCycle(silenceSamples: 25_600).stableCycleCount == 1, "25,600 silence samples failed")
        try expect(oneCycle(silenceSamples: 32_000).stableCycleCount == 1, "32,000 silence samples failed")
        try expect(oneCycle(silenceSamples: 32_001).stableCycleCount == 0, "32,001 silence samples qualified")
        try expect(oneCycle(currentMatches: [0, 1, 2]).stableCycleCount == 0, "Missing terminal word qualified")

        let expectedOrdinarySpeechFloors = [
            4_800, 8_000, 11_200, 13_600,
            16_000, 18_400, 20_800, 23_200
        ]
        for (offset, floor) in expectedOrdinarySpeechFloors.enumerated() {
            try expect(
                LineAcceptancePolicy.minimumOrdinarySpeechSpanSampleCount(
                    for: offset + 1
                ) == floor,
                "L\(offset + 1) ordinary speech-span floor drifted"
            )
        }

        let longRange = 10..<18
        let cumulative = Set(longRange)
        func longCycle(_ current: Set<Int>) -> LineEvidence {
            var policy = LineAcceptancePolicy(lineWordRange: longRange)
            return policy.evaluate(
                progress: policyProgress(range: longRange, matches: cumulative, sequence: 1),
                matchedLineWordIndices: current,
                sequence: 1,
                isFreshCycle: true,
                freshSampleCount: 3_200,
                speechSpanSampleCount: 42_400,
                trailingSilenceSampleCount: 6_400,
                lastVoiceOutputSample: 80_000,
                acousticDecision: .identityMatched
            )
        }
        try expect(longCycle([17]).stableCycleCount == 0, "Cumulative history filled the current snapshot")
        try expect(
            longCycle([10, 11, 12, 13, 14, 16, 17]).stableCycleCount == 1,
            "One ordered decoder omission was not tolerated on a long line"
        )
        try expect(
            longCycle([10, 11, 12, 13, 14, 15, 17]).stableCycleCount == 1,
            "Existing long-line match/prefix floors rejected a qualifying snapshot"
        )
    }

    func testMarkerAndFreshResetSemantics() throws {
        let range = 0..<2
        let matches = Set(range)
        var policy = LineAcceptancePolicy(lineWordRange: range)

        func evaluate(
            _ sequence: UInt64,
            fresh: Bool = true,
            marker: Int64 = 20_000,
            silenceSamples: Int = 6_400,
            decision: AcousticDecision = .identityMatched
        ) -> LineEvidence {
            policy.evaluate(
                progress: policyProgress(range: range, matches: matches, sequence: sequence),
                matchedLineWordIndices: matches,
                sequence: sequence,
                isFreshCycle: fresh,
                freshSampleCount: 3_200,
                speechSpanSampleCount: 16_800,
                trailingSilenceSampleCount: silenceSamples,
                lastVoiceOutputSample: marker,
                acousticDecision: decision
            )
        }

        var evidence = evaluate(1)
        try expect(evidence.stableCycleCount == 1, "First qualifying cycle did not start at one")
        evidence = evaluate(1, decision: .rejected)
        try expect(evidence.stableCycleCount == 1, "Duplicate fresh callback reset stability")
        evidence = evaluate(2, fresh: false, decision: .rejected)
        try expect(evidence.stableCycleCount == 1, "Nonfresh callback reset stability")
        evidence = evaluate(0, decision: .rejected)
        try expect(evidence.stableCycleCount == 1, "Stale callback reset stability")
        evidence = evaluate(2)
        try expect(evidence.stableCycleCount == 2, "Newer qualifying cycle did not increment")

        evidence = evaluate(3, marker: 21_000)
        try expect(evidence.stableCycleCount == 1, "Changed marker did not restart at cycle one")
        evidence = evaluate(4, marker: 21_000)
        try expect(evidence.stableCycleCount == 2, "Stable changed marker did not increment")
        evidence = evaluate(5, marker: 21_000, silenceSamples: 6_399)
        try expect(evidence.stableCycleCount == 0, "Newer fresh nonqualifier did not reset")
        evidence = evaluate(6, marker: 21_000)
        try expect(evidence.stableCycleCount == 1, "Post-reset qualifier did not restart at one")
    }

    func testCycleCountsAndExplicitReset() throws {
        try expect(LineAcceptancePolicy.requiredStableCycleCount(for: 1) == 1, "L1 ordinary cycle count drifted")
        try expect(LineAcceptancePolicy.requiredStableCycleCount(for: 3) == 1, "L3 ordinary cycle count drifted")
        try expect(LineAcceptancePolicy.requiredStableCycleCount(for: 4) == 1, "L4 ordinary cycle count drifted")
        try expect(LineAcceptancePolicy.requiredStableCycleCount(for: 8) == 1, "L8 ordinary cycle count drifted")

        let range = 0..<3
        let matches = Set(range)
        var policy = LineAcceptancePolicy(lineWordRange: range)
        var evidence: LineEvidence?
        for sequence in 1...3 {
            evidence = policy.evaluate(
                progress: policyProgress(range: range, matches: matches, sequence: UInt64(sequence)),
                matchedLineWordIndices: matches,
                sequence: UInt64(sequence),
                isFreshCycle: true,
                freshSampleCount: 3_200,
                speechSpanSampleCount: 23_200,
                trailingSilenceSampleCount: 6_400 + ((sequence - 1) * 3_200),
                lastVoiceOutputSample: 30_000,
                acousticDecision: .identityMatched
            )
            try expect(evidence?.isAccepted == true, "A complete ordinary line did not accept on its first terminal observation")
        }
        try expect(evidence?.acceptedWordCount == evidence?.matchedLineWordIndices.count, "Accepted heuristic did not report its accepted word count")
        policy.reset()
        evidence = policy.evaluate(
            progress: policyProgress(range: range, matches: matches, sequence: 4),
            matchedLineWordIndices: matches,
            sequence: 4,
            isFreshCycle: true,
            freshSampleCount: 3_200,
            speechSpanSampleCount: 23_200,
            trailingSilenceSampleCount: 6_400,
            lastVoiceOutputSample: 30_000,
            acousticDecision: .identityMatched
        )
        try expect(evidence?.stableCycleCount == 1, "Explicit reset did not clear stability")
        try expect(evidence?.isAccepted == true, "A complete ordinary line required a repeat after reset")

        // Later duplicate terminal observations remain harmless after the
        // first accepted ordinary cycle, including real tap/poll jitter.
        var jitteredPolicy = LineAcceptancePolicy(lineWordRange: range)
        let jitteredSilence = [6_547, 9_960, 13_537]
        let jitteredFresh = [3_200, 3_413, 3_577]
        for index in jitteredSilence.indices {
            evidence = jitteredPolicy.evaluate(
                progress: policyProgress(
                    range: range,
                    matches: matches,
                    sequence: UInt64(index + 1)
                ),
                matchedLineWordIndices: matches,
                sequence: UInt64(index + 1),
                isFreshCycle: true,
                freshSampleCount: jitteredFresh[index],
                speechSpanSampleCount: 23_200,
                trailingSilenceSampleCount: jitteredSilence[index],
                lastVoiceOutputSample: 31_337,
                acousticDecision: .identityMatched
            )
        }
        try expect(
            evidence?.isAccepted == true,
            "Jittered post-acceptance observations lost ordinary acceptance"
        )

        // At a 16 kHz input rate, a 1,024-frame microphone tap can leave only
        // 3,072 new samples at a 200 ms poll. The relay waits for the next poll,
        // producing roughly 6,144-sample-fresh snapshots. These later samples
        // must not revoke the first accepted ordinary observation.
        var quantizedRelayPolicy = LineAcceptancePolicy(
            lineWordRange: range
        )
        let quantizedSilence = [12_288, 19_456, 25_600]
        let quantizedFresh = [6_144, 7_168, 6_144]
        for index in quantizedSilence.indices {
            evidence = quantizedRelayPolicy.evaluate(
                progress: policyProgress(
                    range: range,
                    matches: matches,
                    sequence: UInt64(index + 1)
                ),
                matchedLineWordIndices: matches,
                sequence: UInt64(index + 1),
                isFreshCycle: true,
                freshSampleCount: quantizedFresh[index],
                speechSpanSampleCount: 23_200,
                trailingSilenceSampleCount: quantizedSilence[index],
                lastVoiceOutputSample: 40_000,
                acousticDecision: .identityMatched
            )
        }
        try expect(
            evidence?.isAccepted == true,
            "Tap-quantized relay cadence revoked ordinary acceptance"
        )

        // `Task.sleep(200 ms)` is a minimum rather than an exact clock. This
        // observed 210...230 ms-style phase must also retain all three cycles.
        var delayedRelayPolicy = LineAcceptancePolicy(
            lineWordRange: range
        )
        let delayedSilence = [13_312, 20_480, 27_648]
        let delayedFresh = [6_144, 7_168, 7_168]
        for index in delayedSilence.indices {
            evidence = delayedRelayPolicy.evaluate(
                progress: policyProgress(
                    range: range,
                    matches: matches,
                    sequence: UInt64(index + 1)
                ),
                matchedLineWordIndices: matches,
                sequence: UInt64(index + 1),
                isFreshCycle: true,
                freshSampleCount: delayedFresh[index],
                speechSpanSampleCount: 23_200,
                trailingSilenceSampleCount: delayedSilence[index],
                lastVoiceOutputSample: 41_000,
                acousticDecision: .identityMatched
            )
        }
        try expect(
            evidence?.isAccepted == true,
            "Delayed tap/poll cadence revoked ordinary acceptance"
        )
    }

    func testStandaloneMuqattaatAutomaticAcceptance() throws {
        try MuqattaatEndpointAuthorityResolver.validateFrozenContract()
        try expect(
            MuqattaatEndpointAuthorityResolver.allAuthorities.count == 20,
            "Standalone Muqatta'at authority count drifted"
        )

        let forms = MuqattaatForm.allCases
        for (index, form) in forms.enumerated() {
            guard let authority = MuqattaatEndpointAuthorityResolver
                .allAuthorities.first(where: { $0.form == form }) else {
                throw Failure(description: "Muqatta'at form lacked an authority")
            }
            let canonical = authority.expectedCanonicalTokenIDs
            try expect(
                MuqattaatAutomaticIdentity.decision(
                    decodedTokenIDs: [999] + canonical,
                    authority: authority
                ) == .identityMatched,
                "Full canonical suffix did not identify \(form.rawValue)"
            )
            for prefixLength in 0..<canonical.count {
                try expect(
                    MuqattaatAutomaticIdentity.decision(
                        decodedTokenIDs: Array(canonical.prefix(prefixLength)),
                        authority: authority
                    ) == .rejected,
                    "Proper canonical prefix identified \(form.rawValue)"
                )
            }
            let wrongSuffixToken = canonical.last == 1_023 ? 1_022 : 1_023
            try expect(
                MuqattaatAutomaticIdentity.decision(
                    decodedTokenIDs: canonical + [wrongSuffixToken],
                    authority: authority
                ) == .rejected,
                "A wrong suffix identified \(form.rawValue)"
            )
            let wrongForm = forms[(index + 1) % forms.count]
            try expect(
                MuqattaatAutomaticIdentity.decision(
                    decodedTokenIDs: wrongForm.canonicalTokenIDs,
                    authority: authority
                ) == .rejected,
                "A different full Muqatta'at form identified \(form.rawValue)"
            )
        }

        for expected in MuqattaatEndpointAuthorityResolver.allAuthorities {
            let resolved = try MuqattaatEndpointAuthorityResolver.resolve(
                surahNumber: expected.location.surahNumber,
                ayahNumber: expected.location.ayahNumber,
                ayahWordRange: expected.location.ayahWordRange,
                normalizedWords: expected.expectedNormalizedWords,
                canonicalTokenIDs: expected.expectedCanonicalTokenIDs
            )
            try expect(resolved == expected, "A standalone Muqatta'at target fell through")

            let configured = try MuqattaatEndpointAuthorityResolver
                .resolveAutomaticTarget(
                    surahNumber: expected.location.surahNumber,
                    ayahNumber: expected.location.ayahNumber,
                    ayahWordRange: expected.location.ayahWordRange,
                    normalizedWords: expected.expectedNormalizedWords
                )
            try expect(
                configured == expected,
                "An exact standalone Muqatta'at target was not configured automatically"
            )

            let range = expected.location.ayahWordRange
            let matches = Set(range)
            let speechFloor = LineAcceptancePolicy
                .minimumSpeechSpanSampleCount(for: expected.form.spokenLetterCount)
            var belowFloorPolicy = LineAcceptancePolicy(
                lineWordRange: range,
                standaloneMuqattaatForm: expected.form
            )
            let belowFloor = belowFloorPolicy.evaluate(
                progress: policyProgress(range: range, matches: matches, sequence: 1),
                matchedLineWordIndices: matches,
                sequence: 1,
                isFreshCycle: true,
                freshSampleCount: 3_200,
                speechSpanSampleCount: speechFloor - 1,
                trailingSilenceSampleCount: 6_400,
                lastVoiceOutputSample: 60_000,
                acousticDecision: .identityMatched
            )
            try expect(
                belowFloor.stableCycleCount == 0,
                "A standalone Muqatta'at form ignored its spoken-letter floor"
            )

            var automaticPolicy = LineAcceptancePolicy(
                lineWordRange: range,
                standaloneMuqattaatForm: expected.form
            )
            var evidence: LineEvidence?
            for sequence in 1...3 {
                evidence = automaticPolicy.evaluate(
                    progress: policyProgress(
                        range: range,
                        matches: matches,
                        sequence: UInt64(sequence)
                    ),
                    matchedLineWordIndices: matches,
                    sequence: UInt64(sequence),
                    isFreshCycle: true,
                    freshSampleCount: 3_200,
                    speechSpanSampleCount: speechFloor,
                    trailingSilenceSampleCount: 6_400 + ((sequence - 1) * 3_200),
                    lastVoiceOutputSample: 60_000,
                    acousticDecision: .identityMatched
                )
                try expect(
                    evidence?.isAccepted == (sequence == 3),
                    "A standalone Muqatta'at form accepted at the wrong cycle"
                )
            }
            try expect(
                evidence?.requiredStableCycleCount == 3,
                "A standalone Muqatta'at form did not require three stable cycles"
            )
            try expect(
                evidence?.minimumSpeechSpanSampleCount == speechFloor,
                "A standalone Muqatta'at form exposed the wrong speech floor"
            )
            try expect(
                evidence?.acceptedWordCount == evidence?.matchedLineWordIndices.count,
                "An automatically accepted Muqatta'at form did not report its accepted word count"
            )
        }

        guard let first = MuqattaatEndpointAuthorityResolver.allAuthorities.first else {
            throw Failure(description: "Muqatta'at authority table was empty")
        }
        do {
            _ = try MuqattaatEndpointAuthorityResolver.resolve(
                surahNumber: first.location.surahNumber,
                ayahNumber: first.location.ayahNumber,
                ayahWordRange: first.location.ayahWordRange,
                normalizedWords: first.expectedNormalizedWords,
                canonicalTokenIDs: first.expectedCanonicalTokenIDs + [999]
            )
            throw Failure(description: "Muqatta'at catalog mismatch was not rejected")
        } catch is MuqattaatEndpointAuthorityError {
            // A frozen catalog mismatch is a configuration error.
        }
        do {
            _ = try MuqattaatEndpointAuthorityResolver.resolveAutomaticTarget(
                surahNumber: first.location.surahNumber,
                ayahNumber: first.location.ayahNumber,
                ayahWordRange: first.location.ayahWordRange,
                normalizedWords: ["different"]
            )
            throw Failure(description: "Automatic target accepted changed Muqatta'at text")
        } catch is MuqattaatEndpointAuthorityError {
            // Strict target configuration rejected the mismatch.
        }
        do {
            _ = try MuqattaatEndpointAuthorityResolver.resolveAutomaticTarget(
                surahNumber: 1,
                ayahNumber: 1,
                ayahWordRange: 0..<1,
                normalizedWords: [MuqattaatForm.haMim.rawValue]
            )
            throw Failure(description: "Unexpected standalone Muqatta'at form was accepted")
        } catch is MuqattaatEndpointAuthorityError {
            // Planner drift is a configuration error, not another runtime mode.
        }
        let ordinary = try MuqattaatEndpointAuthorityResolver
            .resolveAutomaticTarget(
                surahNumber: 1,
                ayahNumber: 1,
                ayahWordRange: 0..<1,
                normalizedWords: ["الله"]
            )
        try expect(
            ordinary == nil,
            "An ordinary target was classified as standalone Muqatta'at"
        )
        let mixed = try MuqattaatEndpointAuthorityResolver
            .resolveAutomaticTarget(
                surahNumber: 40,
                ayahNumber: 2,
                ayahWordRange: 0..<2,
                normalizedWords: [MuqattaatForm.haMim.rawValue, "تنزيل"]
            )
        try expect(
            mixed == nil,
            "A Muqatta'at opening followed by ordinary words entered the standalone profile"
        )
    }

    func testLatestOnlyInferenceRetention() throws {
        try expect(
            OnnxRunner.defaultIntraOpThreadCount == 2,
            "ONNX thread default drifted from the September 2 recitation/render contention ruling"
        )
        try expect(
            OnnxRunner.maximumPendingInferenceCount == 1,
            "Runner no longer retains exactly one newest pending inference"
        )
        var queue = BoundedFIFO<Int>(
            capacity: OnnxRunner.maximumPendingInferenceCount
        )
        try expect(queue.capacity == 1, "Inference queue capacity drifted")
        try expect(queue.isEmpty, "New inference FIFO was not empty")
        try expect(queue.append(1) == nil, "First inference was unexpectedly dropped")
        try expect(queue.append(2) == 1, "New window did not supersede the pending window")
        try expect(queue.append(3) == 2, "Newest window was not retained")
        try expect(queue.count == 1, "Inference queue exceeded latest-only bound")
        try expect(queue.popFirst() == 3, "Inference queue did not return the newest window")
        try expect(queue.append(4) == nil, "Refilled inference queue dropped a value")
        try expect(queue.drain() == [4], "Inference queue drain drifted")
        try expect(queue.isEmpty, "Inference FIFO was not empty after drain")
        try expect(queue.popFirst() == nil, "Empty inference FIFO returned a value")
    }

    func testLatencySchedulerMailbox() throws {
        try expect(
            LiveLatencyTuning.readinessPollNanoseconds == 12_000_000,
            "Live readiness poll drifted from the September 2 fixed 12 ms cadence"
        )
        try expect(
            LiveLatencyTuning.audioTapBufferSize == 512,
            "Live microphone tap drifted from the measured 512-frame quantum"
        )
        try expect(
            LiveLatencyTuning.maximumLiveModelSampleCount == 16_000 * 2,
            "Live ONNX work escaped the two-second rendering coexistence bound"
        )
        var mailbox = NewestSnapshotMailbox<Int>()
        try expect(mailbox.isEmpty, "New snapshot mailbox was not empty")
        mailbox.offer(1, isTerminal: false)
        mailbox.offer(2, isTerminal: false)
        try expect(mailbox.count == 1, "Mailbox retained stale in-window work")
        try expect(mailbox.takeNext() == 2, "Mailbox did not retain the newest window")

        mailbox.offer(3, isTerminal: false)
        mailbox.offer(9, isTerminal: true)
        try expect(mailbox.count == 2, "Endpoint mailbox exceeded its two-slot bound")
        try expect(
            mailbox.takeNext() == 3,
            "Terminal snapshot erased the final calibrated policy-window snapshot"
        )
        try expect(mailbox.takeNext() == 9, "Terminal snapshot order drifted")

        mailbox.offer(10, isTerminal: true)
        mailbox.offer(11, isTerminal: false)
        try expect(
            mailbox.takeNext() == 11 && mailbox.takeNext() == nil,
            "Fresh voice did not invalidate the prior utterance's terminal snapshot"
        )
        mailbox.offer(12, isTerminal: false)
        mailbox.removeAll()
        try expect(mailbox.isEmpty, "Snapshot mailbox reset left pending work")

        var leases = SharedTaskLeaseLedger()
        let sharedGeneration = leases.beginGeneration()
        let visiblePrewarm = leases.acquire(generation: sharedGeneration)
        let foregroundStart = leases.acquire(generation: sharedGeneration)
        let prewarmRelease = leases.release(visiblePrewarm)
        try expect(
            prewarmRelease.remainingWaiterCount == 1
                && !prewarmRelease.shouldCancelCurrentTask,
            "Canceled visible prewarm incorrectly canceled a foreground waiter"
        )
        let foregroundRelease = leases.release(foregroundStart)
        try expect(
            foregroundRelease.shouldCancelCurrentTask,
            "Final current-generation preparation waiter did not cancel shared work"
        )
        try expect(
            !leases.release(foregroundStart).wasActive,
            "Preparation lease could be released twice"
        )

        let staleGeneration = leases.beginGeneration()
        let staleWaiter = leases.acquire(generation: staleGeneration)
        let replacementGeneration = leases.beginGeneration()
        let replacementWaiter = leases.acquire(generation: replacementGeneration)
        try expect(
            !leases.release(staleWaiter).shouldCancelCurrentTask,
            "Stale waiter canceled a replacement preparation generation"
        )
        try expect(
            leases.release(replacementWaiter).shouldCancelCurrentTask,
            "Replacement generation lost final-waiter cancellation"
        )
    }

    func testExactGreedyTokenFrameProgress() throws {
        let blank = 1_024
        let partial = ExpectedTokenFrameProgressAnalyzer.analyze(
            frameTokenIDs: [
                99, 99, blank,
                10, 10, blank, 11, blank,
                12, 12, 13, 99
            ],
            blankID: blank,
            expectedTokenIDs: [10, 11, 12, 13, 14],
            wordTokenEnds: [2, 5]
        )
        try expect(partial?.completedWordCount == 1, "Exact first word did not complete")
        try expect(partial?.currentWordLocalIndex == 1, "Partial focus skipped the current word")
        try expect(
            abs((partial?.currentWordFraction ?? 0) - (2.0 / 3.0)) < 0.000_001,
            "Current-word token fraction was incorrect"
        )
        try expect(partial?.matchedTokenCount == 4, "Exact token prefix count drifted")
        try expect(partial?.divergentTokenID == 99, "Concrete divergent token was lost")

        let gapped = ExpectedTokenFrameProgressAnalyzer.analyze(
            frameTokenIDs: [10, blank, 99, blank, 11],
            blankID: blank,
            expectedTokenIDs: [10, 11, 12],
            wordTokenEnds: [2, 3]
        )
        try expect(
            gapped?.matchedTokenCount == 1,
            "Greedy token progress skipped across a divergent token"
        )
        try expect(
            gapped?.completedWordCount == 0,
            "A partial word manufactured completed prior-word coverage"
        )

        let complete = ExpectedTokenFrameProgressAnalyzer.analyze(
            frameTokenIDs: [10, blank, 11, blank, 12, blank, 13, blank, 14],
            blankID: blank,
            expectedTokenIDs: [10, 11, 12, 13, 14],
            wordTokenEnds: [2, 5]
        )
        try expect(complete?.completedWordCount == 2, "Exact full line did not complete")
        try expect(complete?.currentWordLocalIndex == nil, "Complete line retained a current word")
        try expect(complete?.currentWordFraction == 0, "Nil current word retained a fraction")
        try expect(complete?.hasCurrentWordDivergence == false, "Exact line diverged")

        let displayProgress = InternalLineProgress(
            sessionID: fixedSessionID,
            sequence: 77,
            surahNumber: 112,
            ayahNumber: 1,
            focusWordIndex: 4,
            lineWordRange: 3..<5,
            cumulativeMatchedWordIndices: [],
            contiguousMatchedWordRange: 3..<3,
            completedWordRange: 3..<4,
            currentWordIndex: 4,
            currentWordFraction: 2.0 / 3.0,
            currentWordPronunciation: .tracking,
            lineRetrySuggested: true
        )
        try expect(displayProgress.sessionID == fixedSessionID, "Display session fence drifted")
        try expect(displayProgress.sequence == 77, "Display sequence fence drifted")
        try expect(displayProgress.completedWordRange == 3..<4, "Display prefix drifted")
        try expect(displayProgress.currentWordIndex == 4, "Display current word drifted")
        try expect(
            abs(displayProgress.currentWordFraction - (2.0 / 3.0)) < 0.000_001,
            "Display partial fraction drifted"
        )
        try expect(displayProgress.lineRetrySuggested, "Scoped line-retry cue was lost")
    }

    func testAuditedFatihaSiratPronunciationVariant() throws {
        let canonical = [117, 17, 40]
        let alternate = QuranPronunciationTokenVariants
            .auditedAlternateTokenization(
                expectedTokenIDs: canonical,
                wordTokenEnds: [3],
                surahNumber: 1,
                ayahNumber: 7,
                ayahWordRange: 0..<1
            )
        try expect(
            alternate?.tokenIDs == [117, 112, 40],
            "Al-Fatiha 1:7 did not admit the model's real fused-ra spelling"
        )
        try expect(
            alternate?.wordTokenEnds == [3],
            "Al-Fatiha 1:7 alternate shifted the word boundary incorrectly"
        )

        let ayahSix = QuranPronunciationTokenVariants
            .auditedAlternateTokenization(
                expectedTokenIDs: [9, 10, 117, 17, 40, 22],
                wordTokenEnds: [2, 5, 6],
                surahNumber: 1,
                ayahNumber: 6,
                ayahWordRange: 0..<3
            )
        try expect(
            ayahSix?.tokenIDs == [9, 10, 117, 112, 40, 22],
            "Al-Fatiha 1:6 did not admit the model's real fused-ra spelling"
        )
        try expect(
            ayahSix?.wordTokenEnds == [2, 5, 6],
            "Al-Fatiha 1:6 alternate shifted unrelated word boundaries"
        )

        for location in [(2, 1, 0..<1), (1, 7, 1..<2), (1, 5, 0..<1)] {
            let unscoped = QuranPronunciationTokenVariants
                .auditedAlternateTokenization(
                    expectedTokenIDs: canonical,
                    wordTokenEnds: [3],
                    surahNumber: location.0,
                    ayahNumber: location.1,
                    ayahWordRange: location.2
                )
            try expect(
                unscoped == nil,
                "The Al-Fatiha sirat alternate leaked outside its audited word"
            )
        }

        let blankID = 1_024
        let vocabularySize = 1_025
        // Real bundled-model greedy output for the ordinary written form,
        // reduced to the word's stable unvocalized token path.
        let emitted = [117, blankID, 112, blankID, 40]
        var logProbabilities = Array(
            repeating: Float(-14),
            count: emitted.count * vocabularySize
        )
        for (frame, winner) in emitted.enumerated() {
            logProbabilities[frame * vocabularySize + winner] = -0.01
        }
        let scorer = CTCScorer(blankID: blankID)
        let targetSequences = [canonical, alternate?.tokenIDs ?? []]
        let strongestTarget = try ExpectedLineAcousticEvaluator
            .strongestReachableTargetScore(
                targetSequences,
                logProbabilities: logProbabilities,
                timeSteps: emitted.count,
                vocabularySize: vocabularySize,
                scorer: scorer
            )
        let canonicalOnly = try ExpectedLineAcousticEvaluator
            .strongestReachableTargetScore(
                [canonical],
                logProbabilities: logProbabilities,
                timeSteps: emitted.count,
                vocabularySize: vocabularySize,
                scorer: scorer
            )
        let confuserScore = try scorer.score(
            logProbabilities: logProbabilities,
            timeSteps: emitted.count,
            vocabularySize: vocabularySize,
            tokenIDs: [117, 17, 41]
        ).logProbabilityPerFrame
        try expect(
            (strongestTarget ?? -.infinity) > (canonicalOnly ?? -.infinity),
            "The audited pronunciation path was not allowed to own target score"
        )
        try expect(
            (strongestTarget ?? -.infinity) - confuserScore
                >= OrdinaryLineIdentityHeuristic.minimumMarginPerFrame,
            "Audited sirat logits did not clear the unchanged Quran confuser gate"
        )

        let progress = QuranPronunciationTokenVariants.bestFrameProgress(
            canonical: ExpectedTokenFrameProgressAnalyzer.analyze(
                frameTokenIDs: emitted,
                blankID: blankID,
                expectedTokenIDs: canonical,
                wordTokenEnds: [3]
            ),
            frameTokenIDs: emitted,
            blankID: blankID,
            expectedTokenIDs: canonical,
            wordTokenEnds: [3],
            surahNumber: 1,
            ayahNumber: 7,
            ayahWordRange: 0..<1
        )
        try expect(
            progress?.completedWordCount == 1,
            "Audited sirat decode still produced a false current-word stall"
        )
    }

    func testAuditedAlIkhlasAhadPronunciationVariant() throws {
        let ayahOneCanonical = [380, 114, 59, 49, 154]
        let ayahOne = QuranPronunciationTokenVariants
            .auditedAlternateTokenization(
                expectedTokenIDs: ayahOneCanonical,
                wordTokenEnds: [1, 2, 3, 5],
                surahNumber: 112,
                ayahNumber: 1,
                ayahWordRange: 0..<4
            )
        try expect(
            ayahOne?.tokenIDs == [380, 114, 59, 371],
            "Al-Ikhlas 112:1 did not admit the model's real single-token ahad spelling"
        )
        try expect(
            ayahOne?.wordTokenEnds == [1, 2, 3, 4],
            "Al-Ikhlas 112:1 did not shift the replaced ahad boundary precisely"
        )

        let ayahFourCanonical = [772, 22, 4, 8, 157, 95, 33, 44, 49, 154]
        let ayahFour = QuranPronunciationTokenVariants
            .auditedAlternateTokenization(
                expectedTokenIDs: ayahFourCanonical,
                wordTokenEnds: [1, 4, 5, 8, 10],
                surahNumber: 112,
                ayahNumber: 4,
                ayahWordRange: 0..<5
            )
        try expect(
            ayahFour?.tokenIDs == [772, 22, 4, 8, 157, 95, 33, 44, 371],
            "Al-Ikhlas 112:4 did not admit the model's real single-token ahad spelling"
        )
        try expect(
            ayahFour?.wordTokenEnds == [1, 4, 5, 8, 9],
            "Al-Ikhlas 112:4 did not shift the replaced ahad boundary precisely"
        )

        let outOfScopeLocations = [(112, 2), (113, 1)]
        for location in outOfScopeLocations {
            let unscoped = QuranPronunciationTokenVariants
                .auditedAlternateTokenization(
                    expectedTokenIDs: [49, 154],
                    wordTokenEnds: [2],
                    surahNumber: location.0,
                    ayahNumber: location.1,
                    ayahWordRange: 0..<1
                )
            try expect(
                unscoped == nil,
                "The Al-Ikhlas ahad alternate leaked outside its two audited words"
            )
        }
        let excludedAyahOneWord = QuranPronunciationTokenVariants
            .auditedAlternateTokenization(
                expectedTokenIDs: [380, 114, 49, 154],
                wordTokenEnds: [1, 2, 4],
                surahNumber: 112,
                ayahNumber: 1,
                ayahWordRange: 0..<3
            )
        try expect(
            excludedAyahOneWord == nil,
            "The 112:1 ahad alternate leaked into an excluded ayah word range"
        )
        let excludedAyahFourWord = QuranPronunciationTokenVariants
            .auditedAlternateTokenization(
                expectedTokenIDs: [772, 22, 4, 8, 157, 49, 154],
                wordTokenEnds: [1, 4, 5, 7],
                surahNumber: 112,
                ayahNumber: 4,
                ayahWordRange: 0..<4
            )
        try expect(
            excludedAyahFourWord == nil,
            "The 112:4 ahad alternate leaked into an excluded ayah word range"
        )
        let wrongCanonicalSpelling = QuranPronunciationTokenVariants
            .auditedAlternateTokenization(
                expectedTokenIDs: [380, 114, 59, 49, 155],
                wordTokenEnds: [1, 2, 3, 5],
                surahNumber: 112,
                ayahNumber: 1,
                ayahWordRange: 0..<4
            )
        try expect(
            wrongCanonicalSpelling == nil,
            "The Al-Ikhlas ahad alternate accepted an unaudited canonical token pair"
        )

        let blankID = 1_024
        let vocabularySize = 1_025
        let emitted = [380, blankID, 114, blankID, 59, blankID, 371]
        var logProbabilities = Array(
            repeating: Float(-14),
            count: emitted.count * vocabularySize
        )
        for (frame, winner) in emitted.enumerated() {
            logProbabilities[frame * vocabularySize + winner] = -0.01
        }
        let scorer = CTCScorer(blankID: blankID)
        let strongestTarget = try ExpectedLineAcousticEvaluator
            .strongestReachableTargetScore(
                [ayahOneCanonical, ayahOne?.tokenIDs ?? []],
                logProbabilities: logProbabilities,
                timeSteps: emitted.count,
                vocabularySize: vocabularySize,
                scorer: scorer
            )
        let canonicalOnly = try ExpectedLineAcousticEvaluator
            .strongestReachableTargetScore(
                [ayahOneCanonical],
                logProbabilities: logProbabilities,
                timeSteps: emitted.count,
                vocabularySize: vocabularySize,
                scorer: scorer
            )
        try expect(
            (strongestTarget ?? -.infinity) > (canonicalOnly ?? -.infinity),
            "The audited ahad spelling was not allowed to own target score"
        )

        let canonicalProgress = ExpectedTokenFrameProgressAnalyzer.analyze(
            frameTokenIDs: emitted,
            blankID: blankID,
            expectedTokenIDs: ayahOneCanonical,
            wordTokenEnds: [1, 2, 3, 5]
        )
        try expect(
            canonicalProgress?.completedWordCount == 3,
            "The frozen canonical ahad spelling unexpectedly consumed token 371"
        )
        let bestProgress = QuranPronunciationTokenVariants.bestFrameProgress(
            canonical: canonicalProgress,
            frameTokenIDs: emitted,
            blankID: blankID,
            expectedTokenIDs: ayahOneCanonical,
            wordTokenEnds: [1, 2, 3, 5],
            surahNumber: 112,
            ayahNumber: 1,
            ayahWordRange: 0..<4
        )
        try expect(
            bestProgress?.completedWordCount == 4,
            "Audited ahad decode still produced a false final-word stall"
        )
        try expect(
            bestProgress?.matchedTokenCount == 4,
            "Audited ahad frame progress retained the replaced two-token boundary"
        )
    }

    func testImmediateContinuationAcousticFence() throws {
        let current = [0, 1]
        let continuation = [2, 3]
        let gatedTargets = ExpectedLineAcousticEvaluator
            .ordinaryTargetTokenSequences(
                currentTargetTokenSequences: [current],
                immediateContinuationTokenIDs: continuation,
                currentLineTextGateSatisfied: true
            )
        try expect(
            gatedTargets == [current, current + continuation],
            "A lexically authorized continuation did not join the current target"
        )
        let ungatedTargets = ExpectedLineAcousticEvaluator
            .ordinaryTargetTokenSequences(
                currentTargetTokenSequences: [current],
                immediateContinuationTokenIDs: continuation,
                currentLineTextGateSatisfied: false
            )
        try expect(
            ungatedTargets == [current],
            "Future speech joined the target before the current text gate passed"
        )

        let blankID = 4
        let vocabularySize = 5
        let scorer = CTCScorer(blankID: blankID)
        func logits(favoring emitted: [Int]) -> [Float] {
            var values = Array(
                repeating: Float(-14),
                count: emitted.count * vocabularySize
            )
            for (frame, winner) in emitted.enumerated() {
                values[frame * vocabularySize + winner] = -0.01
            }
            return values
        }
        func marginAgainstBareContinuation(emitted: [Int]) throws -> Double {
            let values = logits(favoring: emitted)
            let strongestTarget = try ExpectedLineAcousticEvaluator
                .strongestReachableTargetScore(
                    gatedTargets,
                    logProbabilities: values,
                    timeSteps: emitted.count,
                    vocabularySize: vocabularySize,
                    scorer: scorer
                ) ?? -.infinity
            let continuationScore = try scorer.score(
                logProbabilities: values,
                timeSteps: emitted.count,
                vocabularySize: vocabularySize,
                tokenIDs: continuation
            ).logProbabilityPerFrame
            return strongestTarget - continuationScore
        }

        let fullPassageMargin = try marginAgainstBareContinuation(
            emitted: [0, blankID, 1, blankID, 2, blankID, 3]
        )
        try expect(
            fullPassageMargin
                >= OrdinaryLineIdentityHeuristic.minimumMarginPerFrame,
            "Current plus continuation lost to its bare continuation"
        )
        let futureOnlyMargin = try marginAgainstBareContinuation(
            emitted: [2, blankID, 3]
        )
        try expect(
            futureOnlyMargin
                < OrdinaryLineIdentityHeuristic.minimumMarginPerFrame,
            "Bare continuation audio could pass as current plus continuation"
        )
    }

    func testEarlySilenceEvidenceReuse() throws {
        let range = 0..<2
        let matches = Set(range)
        var policy = LineAcceptancePolicy(lineWordRange: range)
        func evaluate(sequence: UInt64, silence: Int) -> LineEvidence {
            policy.evaluate(
                progress: policyProgress(
                    range: range,
                    matches: matches,
                    sequence: sequence
                ),
                matchedLineWordIndices: matches,
                sequence: sequence,
                isFreshCycle: true,
                freshSampleCount: 3_200,
                speechSpanSampleCount: 16_800,
                trailingSilenceSampleCount: silence,
                lastVoiceOutputSample: 48_000,
                acousticDecision: .identityMatched
            )
        }

        var evidence = evaluate(sequence: 1, silence: 0)
        try expect(
            evidence.contentAndAcousticQualifyIgnoringSilence,
            "An exact early-silence analysis was not retainable"
        )
        try expect(!evidence.currentCycleQualifies, "Early silence qualified acceptance")
        try expect(evidence.stableCycleCount == 0, "Early silence counted stability")

        for (sequence, silence) in [(2, 6_400), (3, 9_600), (4, 12_800)] {
            evidence = evaluate(sequence: UInt64(sequence), silence: silence)
        }
        try expect(evidence.isAccepted, "Retained exact analysis could not finish at real ticks")

        try expect(
            TerminalStabilityTickPlanner.additionalTrailingSilenceTicks(
                after: 0,
                through: 12_800
            ) == [6_400, 9_600, 12_800],
            "Early-silence replay did not use the captured 3,200-sample grid"
        )
    }

    func testConservativePronunciationCuePolicy() throws {
        func signals(
            decision: AcousticDecision = .identityMatched,
            fraction: Double = 0.5,
            divergence: Int? = 99,
            stableCount: Int = 2,
            fenceMatches: Bool = true
        ) -> Bool {
            CurrentWordPronunciationCuePolicy.shouldSignalNeedsRetry(
                acousticDecision: decision,
                currentWordFraction: fraction,
                divergentTokenID: divergence,
                stableAnalysisCount: stableCount,
                candidateFenceMatches: fenceMatches
            )
        }

        try expect(signals(), "Stable identity-supported token stall did not cue retry")
        try expect(
            !signals(decision: .rejected),
            "Wrong-line/noise rejection emitted a pronunciation accusation"
        )
        try expect(
            !signals(decision: .inconclusive),
            "Inconclusive audio emitted a pronunciation accusation"
        )
        try expect(!signals(stableCount: 1), "One unstable analysis emitted needs-retry")
        try expect(!signals(fraction: 0), "A word that never began emitted needs-retry")
        try expect(!signals(divergence: nil), "No divergence emitted needs-retry")
        try expect(!signals(fenceMatches: false), "A stale voice fence emitted needs-retry")
    }

    func testProvisionalFocusAndTerminalReuseFences() throws {
        let range = 3..<7
        try expect(
            ProvisionalWordFocus.focusWordIndex(
                snapshotMatches: [],
                lineWordRange: range
            ) == nil,
            "Empty decoder matches manufactured first-word focus"
        )
        try expect(
            ProvisionalWordFocus.focusWordIndex(
                snapshotMatches: [0, 2, 4, 6, 9],
                lineWordRange: range
            ) == 6,
            "Provisional focus did not choose a real in-line match"
        )

        let session = fixedSessionID
        let fence = VoiceMarkerFence(
            generation: 7,
            voiceEpoch: 11,
            lastVoiceOutputSample: 48_000
        )
        let cached = ReusableInferenceKey(
            voiceFence: fence,
            sessionID: session
        )
        try expect(
            ReusableInferencePolicy.canReuse(
                cachedKey: cached,
                requestedKey: cached,
                trailingSilenceSampleCount: 0
            ),
            "Exact current-marker early-silence analysis was not retainable"
        )
        for changed in [
            ReusableInferenceKey(
                voiceFence: VoiceMarkerFence(
                    generation: 8,
                    voiceEpoch: 11,
                    lastVoiceOutputSample: 48_000
                ),
                sessionID: session
            ),
            ReusableInferenceKey(
                voiceFence: VoiceMarkerFence(
                    generation: 7,
                    voiceEpoch: 12,
                    lastVoiceOutputSample: 48_000
                ),
                sessionID: session
            ),
            ReusableInferenceKey(
                voiceFence: VoiceMarkerFence(
                    generation: 7,
                    voiceEpoch: 11,
                    lastVoiceOutputSample: 48_001
                ),
                sessionID: session
            ),
            ReusableInferenceKey(
                voiceFence: fence,
                sessionID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
            )
        ] {
            try expect(
                !ReusableInferencePolicy.canReuse(
                    cachedKey: cached,
                    requestedKey: changed,
                    trailingSilenceSampleCount: 6_400
                ),
                "Changed generation/session/voice epoch reused terminal evidence"
            )
        }
        try expect(
            !ReusableInferencePolicy.canReuse(
                cachedKey: cached,
                requestedKey: cached,
                trailingSilenceSampleCount: 32_001
            ),
            "Terminal evidence reused beyond the silence ceiling"
        )

        try expect(
            TerminalStabilityTickPlanner.additionalTrailingSilenceTicks(
                after: 6_400,
                through: 16_100
            ) == [9_600, 12_800, 16_000],
            "Captured terminal stability ticks drifted"
        )
        try expect(
            TerminalStabilityTickPlanner.additionalTrailingSilenceTicks(
                after: 28_800,
                through: 80_000
            ) == [32_000],
            "Late-result tick replay exceeded the 2-second ceiling"
        )

        var policy = LineAcceptancePolicy(lineWordRange: 0..<2)
        let matches = Set(0..<2)
        for sequence in 1...2 {
            _ = policy.evaluate(
                progress: policyProgress(
                    range: 0..<2,
                    matches: matches,
                    sequence: UInt64(sequence)
                ),
                matchedLineWordIndices: matches,
                sequence: UInt64(sequence),
                isFreshCycle: true,
                freshSampleCount: 3_200,
                speechSpanSampleCount: 16_800,
                trailingSilenceSampleCount: 6_400 + ((sequence - 1) * 3_200),
                lastVoiceOutputSample: 48_000,
                acousticDecision: .identityMatched
            )
        }
        try expect(policy.stableCycleCount == 2, "Reuse fixture did not reach cycle two")
        policy.observeEmptyFreshCycle(sequence: 3, isFreshCycle: true)
        try expect(
            policy.stableCycleCount == 0,
            "Empty current-marker snapshot did not reset stability"
        )
    }

    private func policyProgress(
        range: Range<Int>,
        matches: Set<Int>,
        sequence: UInt64
    ) -> InternalLineProgress {
        var upperBound = range.lowerBound
        while upperBound < range.upperBound, matches.contains(upperBound) {
            upperBound += 1
        }
        return InternalLineProgress(
            sessionID: fixedSessionID,
            sequence: sequence,
            surahNumber: 112,
            ayahNumber: 1,
            focusWordIndex: matches.max() ?? range.lowerBound,
            lineWordRange: range,
            cumulativeMatchedWordIndices: matches,
            contiguousMatchedWordRange: range.lowerBound..<upperBound
        )
    }

    private var fixedSessionID: UUID {
        UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    }

    private func makeRequest(
        sessionID: UUID,
        range: Range<Int>,
        totalWords: Int
    ) throws -> RecognitionRequest {
        try RecognitionRequest(
            sessionID: sessionID,
            surahNumber: 112,
            ayahNumber: 1,
            ayahWordRange: range,
            expectedAyahWordCount: totalWords
        )
    }

    private func observation(
        sessionID: UUID,
        sequence: UInt64,
        wordIndexOneBased: Int,
        totalWords: Int,
        matched: [Int]
    ) -> InternalWordProgressObservation {
        InternalWordProgressObservation(
            sessionID: sessionID,
            sequence: sequence,
            surahNumber: 112,
            ayahNumber: 1,
            wordIndexOneBased: wordIndexOneBased,
            totalWords: totalWords,
            matchedWordIndices: matched
        )
    }

    private func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw Failure(description: message) }
    }

    private func expectCTCError(
        _ expected: CTCScorerError,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
            throw Failure(description: "Expected CTC error \(expected), but the operation succeeded")
        } catch let error as CTCScorerError {
            try expect(error == expected, "Expected CTC error \(expected), received \(error)")
        }
    }
}

