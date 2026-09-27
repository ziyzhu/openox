import Foundation

nonisolated struct ModelServiceStreamState {
    private(set) var cursor = 0
    private(set) var text = ""
    private(set) var completed = false

    mutating func accept(_ batch: JSONValue) throws {
        guard let fields = batch.objectValue, case .int(let nextCursor) = fields["nextCursor"],
              let events = fields["events"]?.arrayValue, events.count <= 1000 else {
            throw WebsiteProviderError("Model service returned an invalid event batch")
        }
        guard !completed, nextCursor >= cursor, nextCursor - cursor == events.count else {
            throw WebsiteProviderError("Model service returned out-of-order events")
        }
        var updated = self
        for value in events {
            guard !updated.completed else { throw WebsiteProviderError("Model service returned events after completion") }
            guard let event = value.objectValue else { throw WebsiteProviderError("Invalid model event") }
            switch event["type"]?.stringValue {
            case "text":
                guard let snapshot = event["text"]?.stringValue, snapshot.utf8.count <= 2_000_000 else { throw WebsiteProviderError("Model response is too large") }
                guard snapshot.hasPrefix(updated.text) else { throw WebsiteProviderError("Model service revised already streamed text") }
                updated.text = snapshot
            case "completed": updated.completed = true
            case "failed": throw WebsiteProviderError(event["message"]?.stringValue ?? "Model generation failed", kind: LLMFailureKind(rawValue: event["kind"]?.stringValue ?? "") ?? .provider)
            default: throw WebsiteProviderError("Unknown model event")
            }
        }
        updated.cursor = nextCursor
        self = updated
    }
}
