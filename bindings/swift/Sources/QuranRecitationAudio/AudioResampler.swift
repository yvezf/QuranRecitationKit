import Foundation
/// Stateful linear resampling with a retained boundary sample; chunk-independent output.
public struct AudioResampler: Sendable {
    private let ratio: Double
    private var samples: [Float] = []
    private var position: Double = 0
    public init(inputSampleRate: Double, outputSampleRate: Double = 16000) {
        precondition(inputSampleRate.isFinite && inputSampleRate > 0 && outputSampleRate > 0)
        ratio = inputSampleRate / outputSampleRate
    }
    public mutating func process(_ input: [Float]) -> [Float] {
        samples.append(contentsOf: input)
        var output: [Float] = []
        while position + 1 < Double(samples.count) {
            let index = Int(position); let fraction = Float(position - Double(index))
            output.append(samples[index] * (1 - fraction) + samples[index + 1] * fraction)
            position += ratio
        }
        let discard = min(Int(position), max(0, samples.count - 1))
        samples.removeFirst(discard); position -= Double(discard)
        return output
    }
}
