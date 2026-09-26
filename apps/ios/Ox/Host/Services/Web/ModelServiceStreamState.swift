import Foundation

nonisolated struct ModelServiceStreamState {
    private(set) var cursor = 0
    private(set) var text = ""
    private(set) var completed = false

    mutating func accept(_ update: WebsiteGenerationUpdate) throws {
        guard !completed, update.nextCursor >= cursor,
              update.nextCursor - cursor == update.events.count else {
            throw WebsiteProviderError("Model service returned out-of-order events")
        }
        var next = self
        for event in update.events {
            guard !next.completed else { throw WebsiteProviderError("Model service returned events after completion") }
            switch event {
            case .textSnapshot(let snapshot):
                guard snapshot.hasPrefix(next.text) else { throw WebsiteProviderError("Model service revised already streamed text") }
                next.text = snapshot
            case .completed: next.completed = true
            case .failed(let message, let kind): throw WebsiteProviderError(message, kind: kind)
            }
        }
        next.cursor = update.nextCursor
        self = next
    }
}
