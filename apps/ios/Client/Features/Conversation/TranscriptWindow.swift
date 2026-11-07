import Foundation

struct TranscriptWindow: Equatable {
    static let batchSize = 8

    private(set) var range = 0..<0

    var hasEarlier: Bool { range.lowerBound > 0 }

    func resolvedRange(total: Int) -> Range<Int> {
        guard !range.isEmpty, range.lowerBound < total else { return Self.tailRange(total: total) }
        return range.lowerBound..<total
    }

    mutating func open(total: Int) {
        range = Self.tailRange(total: total)
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
    mutating func anchor(on id: UUID, in blockIDs: [UUID], startingAt lowerBound: Int) -> Bool {
        guard let index = blockIDs.firstIndex(of: id) else { return false }
        range = min(range.lowerBound, lowerBound + index)..<max(range.upperBound, lowerBound + blockIDs.count)
        return true
    }

    mutating func revealEarlier() {
        range = max(0, range.lowerBound - Self.batchSize)..<range.upperBound
    }

    mutating func showLatest(total: Int) {
        range = Self.tailRange(total: total)
    }

    private static func tailRange(total: Int) -> Range<Int> {
        max(0, total - batchSize)..<total
    }
}
