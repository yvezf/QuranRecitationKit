@testable import QuranRecitationKit

import Foundation

/// Cross-language golden fixture for the endpoint-head feature schema.
///
/// The expected vector is emitted by the independent Python calibration
/// implementation from the same Float32 rows. Exact equality is intentional:
/// every published feature is quantized to the contract's 1e-6 grid.
enum EndpointHeadFeatureParityFixture {
    enum Failure: Error, Equatable {
        case featureNameCount(expected: Int, actual: Int)
        case valueCount(expected: Int, actual: Int)
        case valueMismatch(index: Int, expected: Double, actual: Double)
    }

    static func verify() throws {
        let rows: [[Float]] = [
            [-0.20, -2.10, -3.00, -0.40],
            [-0.10, -2.30, -2.80, -1.50],
            [-0.70, -1.30, -2.10, -0.20],
            [-1.80, -0.15, -2.60, -0.90],
            [-2.20, -0.10, -2.50, -1.20],
            [-2.50, -1.60, -2.80, -0.08],
            [-2.80, -2.00, -3.10, -0.05],
        ]
        let actual = try EndpointHeadFeatureExtractor(blankID: 3).extract(
            logProbabilities: rows.flatMap { $0 },
            timeSteps: rows.count,
            vocabularySize: 4,
            targetTokenIDs: [0, 1],
            timing: EndpointSnapshotTiming(
                windowSampleCount: 16_000,
                speechSpanSampleCount: 11_000,
                freshSampleCount: 3_200,
                firstVoiceSampleOffset: 1_000,
                lastVoiceSampleOffsetExclusive: 12_000
            )
        ).values

        let expected: [Double] = [
            -2.607597, -0.907597, 0.730191,
            -2.607597, -0.907597, 0.730191,
            -2.580746, -1.330746, 0.687796,
            -2.553895, -1.753895, 0.645402,
            -2.195283, -1.245283, 0.753045,
            -1.836671, -0.736671, 0.860687,
            -1.198346, -1.023346, 0.814153,
            -0.560021, -1.310021, 0.767619,
            -0.560021, -1.310021, 0.767619,
            -0.497861, -1.422861, 0.737160,
            -0.435700, -1.535700, 0.706700,
            -1.136534, -0.926534, 0.658672,
            -1.837368, -0.317368, 0.610644,
            -2.006678, -0.271678, 0.558794,
            -2.175988, -0.225988, 0.506945,
            -2.175988, -0.225988, 0.506945,
            0.188638, -0.184368, 0.373005, -0.125714,
            0.125000, 0.000000, 0.642857, 0.428571,
            0.714286, 0.571429, 0.285714, 0.428571,
            0.285714, 0.285714, 0.285714, 0.597388,
            0.603196, 0.609004, 0.609004, 0.646812,
            0.083333, 0.687500, 0.200000, 0.062500,
            0.750000, 0.250000, 0.107143, 0.035714,
        ]

        let names = EndpointHeadFeatureVector.featureNames
        guard names.count == EndpointHeadFeatureVector.featureCount else {
            throw Failure.featureNameCount(
                expected: EndpointHeadFeatureVector.featureCount,
                actual: names.count
            )
        }
        guard actual.count == expected.count else {
            throw Failure.valueCount(expected: expected.count, actual: actual.count)
        }
        for index in expected.indices where actual[index] != expected[index] {
            throw Failure.valueMismatch(
                index: index,
                expected: expected[index],
                actual: actual[index]
            )
        }
    }
}

