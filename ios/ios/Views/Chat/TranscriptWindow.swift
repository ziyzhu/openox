import Foundation

struct TranscriptWindow: Equatable {
    enum Mode: Equatable {
        case atTail
        case anchored(UUID)
        case browsing(UUID)

        var label: String {
            switch self {
            case .atTail: "atTail"
            case .anchored(let id): "anchored(\(id.uuidString.prefix(8)))"
            case .browsing(let id): "browsing(\(id.uuidString.prefix(8)))"
            }
        }

        var anchor: UUID? {
            switch self {
            case .atTail: nil
            case .anchored(let id), .browsing(let id): id
            }
        }
    }

    static let batchSize = 32
    static let openingBatchSize = 8

    private(set) var range = 0..<0
    private(set) var total = 0
    private(set) var mode = Mode.atTail
    private(set) var shiftCount = 0
    private(set) var lastShiftDirection: String?
    private(set) var initialBatchSize = Self.batchSize

    var hasEarlier: Bool { range.lowerBound > 0 }
    var loadedEarlierBlocks: Int { max(0, range.count - initialBatchSize) }

    func resolvedRange(total: Int, initialBatchSize: Int = Self.batchSize) -> Range<Int> {
        guard self.total == total,
              range.lowerBound >= 0,
              range.upperBound == total else {
            return Self.tailRange(total: total, batchSize: initialBatchSize)
        }
        return range
    }

    mutating func open(total: Int, initialBatchSize: Int = Self.batchSize) {
        self.total = total
        self.initialBatchSize = initialBatchSize
        range = Self.tailRange(total: total, batchSize: initialBatchSize)
        mode = .atTail
        shiftCount = 0
        lastShiftDirection = nil
    }

    mutating func reconcile(total: Int) {
        self.total = total
        guard total > 0 else {
            range = 0..<0
            mode = .atTail
            return
        }
        guard range.lowerBound < total else {
            range = Self.tailRange(total: total)
            initialBatchSize = Self.batchSize
            mode = .atTail
            return
        }
        range = range.lowerBound..<total
    }

    @discardableResult
    mutating func anchor(on id: UUID, in blockIDs: [UUID]) -> Bool {
        guard let index = blockIDs.firstIndex(of: id) else { return false }
        total = blockIDs.count
        range = min(range.lowerBound, index)..<total
        mode = .anchored(id)
        return true
    }

    @discardableResult
    mutating func readerMoved(visibleAnchor: UUID?) -> Bool {
        guard let visibleAnchor else { return false }
        if case .browsing = mode { return false }
        mode = .browsing(visibleAnchor)
        return true
    }

    mutating func loadEarlier(visibleAnchor: UUID?) -> UUID? {
        guard hasEarlier, let anchor = visibleAnchor ?? mode.anchor else { return nil }
        let previousLowerBound = range.lowerBound
        range = max(0, previousLowerBound - Self.batchSize)..<total
        mode = .browsing(anchor)
        shiftCount += 1
        lastShiftDirection = "earlier"
        return range.lowerBound == previousLowerBound ? nil : anchor
    }

    mutating func showLatest(total: Int) {
        self.total = total
        initialBatchSize = Self.batchSize
        range = Self.tailRange(total: total)
        mode = .atTail
    }

    private static func tailRange(total: Int) -> Range<Int> {
        tailRange(total: total, batchSize: Self.batchSize)
    }

    private static func tailRange(total: Int, batchSize: Int) -> Range<Int> {
        max(0, total - max(0, batchSize))..<total
    }
}
