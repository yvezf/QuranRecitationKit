import Foundation

/// Integer timing captured for the exact PCM window sent to .
///
/// Keeping timing in 16 kHz sample coordinates avoids training/runtime drift
/// from serializing rounded seconds. Voice offsets are relative to the start
/// of this window and `lastVoiceSampleOffsetExclusive` is an exclusive bound.
/// The relay can derive these values in memory; no audio or speaker identity is
/// retained by this contract.
struct EndpointSnapshotTiming: Equatable, Sendable {
    let windowSampleCount: Int
    let speechSpanSampleCount: Int
    let freshSampleCount: Int
    let firstVoiceSampleOffset: Int
    let lastVoiceSampleOffsetExclusive: Int
}

/// The fixed, versioned input to a future tiny endpoint classifier.
///
/// This type deliberately contains features only. It cannot accept a line or
/// mutate  progress, so calibration can be proven before any production
/// acceptance behavior changes.
struct EndpointHeadFeatureVector: Equatable, Sendable {
    static let schemaVersion = 1
    static let binCount = 16
    static let featureCount = 76
    static let quantizationScale = 1_000_000.0

    /// Stable order shared byte-for-byte with the private Python calibration
    /// extractor. A trained head must pin this schema and exact name list.
    static let featureNames: [String] = {
        var names: [String] = []
        names.reserveCapacity(featureCount)
        for bin in 0..<binCount {
            names.append("bin_\(bin)_terminal_token_mean_log_posterior")
            names.append("bin_\(bin)_blank_mean_log_posterior")
            names.append("bin_\(bin)_mean_normalized_entropy")
        }
        names.append(contentsOf: [
            "target_forward_log_probability_per_frame",
            "strongest_strict_prefix_log_probability_per_frame",
            "target_vs_strict_prefix_margin_per_frame",
            "viterbi_log_probability_per_frame",
            "target_token_count_clipped_over_16",
            "first_token_start_frame_fraction",
            "terminal_token_representative_frame_center_fraction",
            "terminal_token_start_frame_fraction",
            "terminal_token_end_frame_fraction",
            "all_token_viterbi_occupancy_fraction",
            "terminal_token_viterbi_occupancy_fraction",
            "blank_viterbi_occupancy_fraction",
            "minimum_token_dwell_fraction",
            "mean_token_dwell_fraction",
            "maximum_token_dwell_fraction",
            "minimum_token_mean_emission_posterior",
            "mean_token_mean_emission_posterior",
            "maximum_token_mean_emission_posterior",
            "terminal_token_mean_emission_posterior",
            "terminal_token_representative_emission_posterior",
            "window_duration_over_12_seconds",
            "speech_span_over_window",
            "fresh_audio_over_window",
            "first_voice_offset_over_window",
            "last_voice_offset_over_window",
            "trailing_voice_silence_over_window",
            "voice_end_minus_terminal_representative_center_over_window",
            "voice_end_minus_terminal_token_end_over_window",
        ])
        return names
    }()

    let values: [Double]

    fileprivate init(values: [Double]) {
        self.values = values
    }
}

enum EndpointHeadFeatureError: Error, Equatable, Sendable {
    case invalidTiming
    case invalidFeatureLayout(expected: Int, actual: Int)
    case nonFiniteFeature(Int)
}

extension EndpointHeadFeatureError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidTiming:
            return "The  endpoint snapshot timing is invalid."
        case let .invalidFeatureLayout(expected, actual):
            return "The  endpoint feature layout expected \(expected) values, not \(actual)."
        case let .nonFiniteFeature(index):
            return " endpoint feature \(index) is not finite."
        }
    }
}

/// Derives a small endpoint-classifier input from one existing ONNX result.
///
/// There is no additional model pass. Forward CTC scores, strict-prefix
/// scores, and Viterbi alignment are inexpensive reductions over the logits
/// already produced for the selected  line.
struct EndpointHeadFeatureExtractor: Sendable {
    static let sampleRate = 16_000
    static let maximumWindowSampleCount = sampleRate * 12

    private let scorer: CTCScorer

    init(blankID: Int = 1_024) {
        scorer = CTCScorer(blankID: blankID)
    }

    func extract(
        logProbabilities: [Float],
        timeSteps: Int,
        vocabularySize: Int,
        targetTokenIDs: [Int],
        timing: EndpointSnapshotTiming
    ) throws -> EndpointHeadFeatureVector {
        try validate(timing: timing)

        // These calls also apply the scorer's pinned shape, token, blank, and
        // finite-input validation before feature arithmetic begins.
        let targetScore = try scorer.score(
            logProbabilities: logProbabilities,
            timeSteps: timeSteps,
            vocabularySize: vocabularySize,
            tokenIDs: targetTokenIDs
        )
        let alignment = try scorer.forcedAlignment(
            logProbabilities: logProbabilities,
            timeSteps: timeSteps,
            vocabularySize: vocabularySize,
            tokenIDs: targetTokenIDs
        )

        var strongestStrictPrefixScore = -Double.infinity
        for prefixCount in 0..<targetTokenIDs.count {
            let score = try scorer.score(
                logProbabilities: logProbabilities,
                timeSteps: timeSteps,
                vocabularySize: vocabularySize,
                tokenIDs: Array(targetTokenIDs.prefix(prefixCount))
            )
            strongestStrictPrefixScore = max(
                strongestStrictPrefixScore,
                score.logProbabilityPerFrame
            )
        }

        let frameChannels = try normalizedFrameChannels(
            logProbabilities: logProbabilities,
            timeSteps: timeSteps,
            vocabularySize: vocabularySize,
            terminalTokenID: targetTokenIDs[targetTokenIDs.count - 1],
            blankID: scorer.blankID
        )

        var features: [Double] = []
        features.reserveCapacity(EndpointHeadFeatureVector.featureCount)
        appendTimeBins(from: frameChannels, to: &features)

        let frameCount = Double(timeSteps)
        let tokenAlignments = alignment.tokenAlignments
        let firstToken = tokenAlignments[0]
        let terminalToken = tokenAlignments[tokenAlignments.count - 1]
        let tokenDwells = tokenAlignments.map {
            Double($0.emissionFrameRange.count) / frameCount
        }
        let tokenPosteriorMeans = tokenAlignments.map { token in
            mean(
                frameChannels.posterior(
                    forTokenID: token.tokenID,
                    logProbabilities: logProbabilities,
                    vocabularySize: vocabularySize,
                    frameRange: token.emissionFrameRange
                )
            )
        }
        let totalTokenFrames = tokenAlignments.reduce(into: 0) {
            $0 += $1.emissionFrameRange.count
        }
        let terminalRepresentativePosterior = frameChannels.posterior(
            forTokenID: terminalToken.tokenID,
            logProbabilities: logProbabilities,
            vocabularySize: vocabularySize,
            frame: terminalToken.representativeEmissionFrame
        )

        let windowSamples = Double(timing.windowSampleCount)
        let firstVoiceFraction = Double(timing.firstVoiceSampleOffset) / windowSamples
        let lastVoiceFraction = Double(timing.lastVoiceSampleOffsetExclusive) / windowSamples
        let terminalRepresentativeFraction =
            (Double(terminalToken.representativeEmissionFrame) + 0.5) / frameCount
        let terminalEndFraction =
            Double(terminalToken.emissionFrameRange.upperBound) / frameCount

        features.append(contentsOf: [
            targetScore.logProbabilityPerFrame,
            strongestStrictPrefixScore,
            targetScore.logProbabilityPerFrame - strongestStrictPrefixScore,
            alignment.viterbiLogProbability / frameCount,
            Double(min(targetTokenIDs.count, 16)) / 16.0,
            Double(firstToken.emissionFrameRange.lowerBound) / frameCount,
            terminalRepresentativeFraction,
            Double(terminalToken.emissionFrameRange.lowerBound) / frameCount,
            terminalEndFraction,
            Double(totalTokenFrames) / frameCount,
            Double(terminalToken.emissionFrameRange.count) / frameCount,
            1.0 - (Double(totalTokenFrames) / frameCount),
            tokenDwells.min() ?? 0,
            mean(tokenDwells),
            tokenDwells.max() ?? 0,
            tokenPosteriorMeans.min() ?? 0,
            mean(tokenPosteriorMeans),
            tokenPosteriorMeans.max() ?? 0,
            tokenPosteriorMeans[tokenPosteriorMeans.count - 1],
            terminalRepresentativePosterior,
            windowSamples / Double(Self.maximumWindowSampleCount),
            Double(timing.speechSpanSampleCount) / windowSamples,
            Double(timing.freshSampleCount) / windowSamples,
            firstVoiceFraction,
            lastVoiceFraction,
            1.0 - lastVoiceFraction,
            lastVoiceFraction - terminalRepresentativeFraction,
            lastVoiceFraction - terminalEndFraction,
        ])

        guard features.count == EndpointHeadFeatureVector.featureCount else {
            throw EndpointHeadFeatureError.invalidFeatureLayout(
                expected: EndpointHeadFeatureVector.featureCount,
                actual: features.count
            )
        }
        let quantized = try features.enumerated().map { index, feature in
            guard feature.isFinite else {
                throw EndpointHeadFeatureError.nonFiniteFeature(index)
            }
            return quantize(feature)
        }
        return EndpointHeadFeatureVector(values: quantized)
    }

    private func validate(timing: EndpointSnapshotTiming) throws {
        guard timing.windowSampleCount > 0,
              timing.windowSampleCount <= Self.maximumWindowSampleCount,
              timing.freshSampleCount > 0,
              timing.freshSampleCount <= timing.windowSampleCount,
              timing.firstVoiceSampleOffset >= 0,
              timing.firstVoiceSampleOffset < timing.lastVoiceSampleOffsetExclusive,
              timing.lastVoiceSampleOffsetExclusive <= timing.windowSampleCount,
              timing.speechSpanSampleCount ==
                timing.lastVoiceSampleOffsetExclusive - timing.firstVoiceSampleOffset else {
            throw EndpointHeadFeatureError.invalidTiming
        }
    }

    private func appendTimeBins(
        from channels: NormalizedFrameChannels,
        to features: inout [Double]
    ) {
        let timeSteps = channels.terminalTokenLogPosterior.count
        let binCount = EndpointHeadFeatureVector.binCount
        for bin in 0..<binCount {
            // The overlapping definition keeps all 16 features meaningful for
            // very short model outputs while remaining ordinary disjoint bins
            // whenever `timeSteps >= 16` and divides evenly.
            let start = min(timeSteps - 1, (bin * timeSteps) / binCount)
            let ceilingNumerator = (bin + 1) * timeSteps + binCount - 1
            let end = min(
                timeSteps,
                max(start + 1, ceilingNumerator / binCount)
            )
            let range = start..<end
            features.append(mean(channels.terminalTokenLogPosterior[range]))
            features.append(mean(channels.blankLogPosterior[range]))
            features.append(mean(channels.normalizedEntropy[range]))
        }
    }

    private func normalizedFrameChannels(
        logProbabilities: [Float],
        timeSteps: Int,
        vocabularySize: Int,
        terminalTokenID: Int,
        blankID: Int
    ) throws -> NormalizedFrameChannels {
        var terminalTokenLogPosterior: [Double] = []
        var blankLogPosterior: [Double] = []
        var normalizedEntropy: [Double] = []
        var logNormalizers: [Double] = []
        terminalTokenLogPosterior.reserveCapacity(timeSteps)
        blankLogPosterior.reserveCapacity(timeSteps)
        normalizedEntropy.reserveCapacity(timeSteps)
        logNormalizers.reserveCapacity(timeSteps)

        let maximumEntropy = log(Double(vocabularySize))
        for frame in 0..<timeSteps {
            let offset = frame * vocabularySize
            var maximum = -Double.infinity
            for tokenID in 0..<vocabularySize {
                maximum = max(maximum, Double(logProbabilities[offset + tokenID]))
            }

            var shiftedProbabilitySum = 0.0
            for tokenID in 0..<vocabularySize {
                shiftedProbabilitySum += exp(
                    Double(logProbabilities[offset + tokenID]) - maximum
                )
            }
            let logNormalizer = maximum + log(shiftedProbabilitySum)

            var posteriorWeightedLogProbability = 0.0
            for tokenID in 0..<vocabularySize {
                let logProbability = Double(logProbabilities[offset + tokenID])
                posteriorWeightedLogProbability +=
                    exp(logProbability - logNormalizer) * logProbability
            }
            let entropy = logNormalizer - posteriorWeightedLogProbability

            terminalTokenLogPosterior.append(
                Double(logProbabilities[offset + terminalTokenID]) - logNormalizer
            )
            blankLogPosterior.append(
                Double(logProbabilities[offset + blankID]) - logNormalizer
            )
            normalizedEntropy.append(min(1, max(0, entropy / maximumEntropy)))
            logNormalizers.append(logNormalizer)
        }
        return NormalizedFrameChannels(
            terminalTokenLogPosterior: terminalTokenLogPosterior,
            blankLogPosterior: blankLogPosterior,
            normalizedEntropy: normalizedEntropy,
            logNormalizers: logNormalizers
        )
    }

    private func mean<C: Collection>(_ values: C) -> Double where C.Element == Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func quantize(_ value: Double) -> Double {
        let scale = EndpointHeadFeatureVector.quantizationScale
        let magnitude = floor(abs(value) * scale + 0.5) / scale
        return value.sign == .minus ? -magnitude : magnitude
    }

    private struct NormalizedFrameChannels {
        let terminalTokenLogPosterior: [Double]
        let blankLogPosterior: [Double]
        let normalizedEntropy: [Double]
        let logNormalizers: [Double]

        func posterior(
            forTokenID tokenID: Int,
            logProbabilities: [Float],
            vocabularySize: Int,
            frame: Int
        ) -> Double {
            exp(
                Double(logProbabilities[frame * vocabularySize + tokenID])
                    - logNormalizers[frame]
            )
        }

        func posterior(
            forTokenID tokenID: Int,
            logProbabilities: [Float],
            vocabularySize: Int,
            frameRange: Range<Int>
        ) -> [Double] {
            frameRange.map {
                posterior(
                    forTokenID: tokenID,
                    logProbabilities: logProbabilities,
                    vocabularySize: vocabularySize,
                    frame: $0
                )
            }
        }
    }
}
