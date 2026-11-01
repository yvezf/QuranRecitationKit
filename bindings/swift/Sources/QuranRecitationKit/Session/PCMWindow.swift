import Foundation

/// Fixed-capacity PCM ring. Ingestion is O(n), without shifting the 12-second tail per tap.
struct PCMWindow: Sendable {
    private var storage: [Float]
    private var head = 0
    private(set) var count = 0
    init(capacity: Int) { storage = [Float](repeating: 0, count: max(1,capacity)) }
    mutating func append<C: Collection>(contentsOf input: C) where C.Element == Float {
        for sample in input {
            if count < storage.count {
                storage[(head + count) % storage.count] = sample; count += 1
            } else { storage[head] = sample; head = (head + 1) % storage.count }
        }
    }
    mutating func discardFirst(_ amount: Int) {
        let n = min(count, max(0,amount)); head = (head+n) % storage.count; count -= n
    }
    var samples: [Float] { (0..<count).map { storage[(head+$0) % storage.count] } }
}
