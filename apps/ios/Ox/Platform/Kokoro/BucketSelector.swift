
import Foundation

nonisolated public func selectBucket(totalSeconds: Double, availableBuckets: [Int]) -> Int? {
    guard !availableBuckets.isEmpty else { return nil }
    let sorted = availableBuckets.sorted()
    let threshold = Int(ceil(totalSeconds))
    for sec in sorted {
        if sec >= threshold {
            return sec
        }
    }
    return nil
}
