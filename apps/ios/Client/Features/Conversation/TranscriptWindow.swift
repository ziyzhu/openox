import Foundation

struct TranscriptWindow: Equatable {
    static let batchSize = 16

    private(set) var start: Int?

    func range(in blocks: Range<Int>) -> Range<Int> {
        guard let start, start < blocks.upperBound else { return Self.tail(of: blocks) }
        return max(start, blocks.lowerBound) - blocks.lowerBound..<blocks.count
    }

    func firstOrdinal(in blocks: Range<Int>) -> Int {
        blocks.lowerBound + range(in: blocks).lowerBound
    }

    func hasEarlier(in blocks: Range<Int>) -> Bool {
        start.map { $0 > blocks.lowerBound } ?? false
    }

    func earlierStart(in blocks: Range<Int>) -> Int {
        max(blocks.lowerBound, (start ?? blocks.lowerBound) - Self.batchSize)
    }

    mutating func open(_ blocks: Range<Int>) {
        start = blocks.isEmpty ? nil : blocks.lowerBound + Self.tail(of: blocks).lowerBound
    }

    mutating func reconcile(_ blocks: Range<Int>) {
        guard !blocks.isEmpty else {
            start = nil
            return
        }
        let current = start ?? blocks.lowerBound
        start = current < blocks.upperBound ? current : blocks.lowerBound + Self.tail(of: blocks).lowerBound
    }

    @discardableResult
    mutating func anchor(on id: UUID, in blockIDs: [UUID], startingAt ordinal: Int, blocks: Range<Int>) -> Bool {
        guard let index = blockIDs.firstIndex(of: id) else { return false }
        start = min(start ?? blocks.lowerBound, ordinal + index)
        return true
    }

    mutating func trim(above id: UUID, in blockIDs: [UUID], startingAt ordinal: Int, blocks: Range<Int>) -> Bool {
        guard let index = blockIDs.firstIndex(of: id) else { return false }
        let anchor = ordinal + index
        guard anchor - (start ?? blocks.lowerBound) > Self.batchSize * 2 else { return false }
        start = anchor - Self.batchSize
        return true
    }

    mutating func revealEarlier(in blocks: Range<Int>) {
        start = earlierStart(in: blocks)
    }

    private static func tail(of blocks: Range<Int>) -> Range<Int> {
        max(0, blocks.count - batchSize)..<blocks.count
    }
}
