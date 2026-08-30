import Foundation

struct TranscriptWindow: Equatable {
    private enum EarlierRequest: Equatable {
        case idle
        case pending(UUID)
    }

    static let batchSize = 32
    static let openingBatchSize = 8

    private(set) var range = 0..<0
    private var earlierBoundaryVisible = false
    private var earlierRequest = EarlierRequest.idle

    var hasEarlier: Bool { range.lowerBound > 0 }

    func resolvedRange(total: Int, initialBatchSize: Int = Self.batchSize) -> Range<Int> {
        guard range.upperBound == total else {
            return Self.tailRange(total: total, batchSize: initialBatchSize)
        }
        return range
    }

    mutating func open(total: Int, initialBatchSize: Int = Self.batchSize) {
        range = Self.tailRange(total: total, batchSize: initialBatchSize)
        earlierBoundaryVisible = false
        earlierRequest = .idle
    }

    mutating func reconcile(total: Int) {
        guard total > 0 else {
            range = 0..<0
            return
        }
        guard range.lowerBound < total else {
            range = Self.tailRange(total: total)
            return
        }
        range = range.lowerBound..<total
    }

    @discardableResult
    mutating func anchor(on id: UUID, in blockIDs: [UUID]) -> Bool {
        earlierRequest = .idle
        guard let index = blockIDs.firstIndex(of: id) else { return false }
        range = min(range.lowerBound, index)..<blockIDs.count
        return true
    }

    mutating func setEarlierBoundaryVisible(_ visible: Bool) {
        earlierBoundaryVisible = visible
    }

    mutating func requestEarlier(anchor: UUID?, isUserScrolling: Bool) {
        guard earlierBoundaryVisible,
              isUserScrolling,
              case .idle = earlierRequest,
              let anchor else { return }
        earlierRequest = .pending(anchor)
    }

    mutating func applyPendingEarlier() -> UUID? {
        guard case .pending(let anchor) = earlierRequest else { return nil }
        earlierRequest = .idle
        guard hasEarlier else { return nil }
        let previousLowerBound = range.lowerBound
        range = max(0, previousLowerBound - Self.batchSize)..<range.upperBound
        return range.lowerBound == previousLowerBound ? nil : anchor
    }

    mutating func showLatest(total: Int) {
        earlierRequest = .idle
        range = Self.tailRange(total: total)
    }

    private static func tailRange(total: Int) -> Range<Int> {
        tailRange(total: total, batchSize: Self.batchSize)
    }

    private static func tailRange(total: Int, batchSize: Int) -> Range<Int> {
        max(0, total - max(0, batchSize))..<total
    }
}
