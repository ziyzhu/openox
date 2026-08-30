import Foundation

struct TranscriptWindow: Equatable {
    private enum EarlierRequest: Equatable {
        case idle
        case pending(UUID)
    }

    static let batchSize = 16

    private(set) var range = 0..<0
    private var earlierBoundaryVisible = false
    private var earlierRequest = EarlierRequest.idle

    var hasEarlier: Bool { range.lowerBound > 0 }

    func resolvedRange(total: Int) -> Range<Int> {
        guard !range.isEmpty, range.lowerBound < total else { return Self.tailRange(total: total) }
        if range.count <= Self.batchSize, range.upperBound != total {
            return Self.tailRange(total: total)
        }
        return range.lowerBound..<total
    }

    mutating func open(total: Int) {
        range = Self.tailRange(total: total)
        earlierBoundaryVisible = false
        earlierRequest = .idle
    }

    mutating func reconcile(total: Int) {
        guard total > 0 else {
            range = 0..<0
            return
        }
        if range.count <= Self.batchSize {
            range = Self.tailRange(total: total)
            return
        }
        guard range.lowerBound < total else {
            range = Self.tailRange(total: total)
            return
        }
        range = range.lowerBound..<total
    }

    @discardableResult
    mutating func anchor(on id: UUID, in blockIDs: [UUID], startingAt lowerBound: Int) -> Bool {
        earlierRequest = .idle
        guard let index = blockIDs.firstIndex(of: id) else { return false }
        range = min(range.lowerBound, lowerBound + index)..<max(range.upperBound, lowerBound + blockIDs.count)
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
        max(0, total - batchSize)..<total
    }
}
