import Foundation

nonisolated struct PartialHistory: Sendable, Equatable {
    let older: JSONValue
    let storedPreview: String?
}

nonisolated enum ConversationHistory: Sendable {
    static let userTurnsPerPage = 5

    case complete
    case partial(PartialHistory)
    case loading(PartialHistory, Task<Void, Never>)

    var partial: PartialHistory? {
        switch self {
        case .complete: nil
        case .partial(let partial), .loading(let partial, _): partial
        }
    }

    var hasOlder: Bool { partial != nil }
}

nonisolated enum ConversationHistoryRequest: Sendable {
    case latest
    case older(JSONValue, userTurns: Int?)

    var userTurns: Int? {
        switch self {
        case .latest: ConversationHistory.userTurnsPerPage
        case .older(_, let userTurns): userTurns
        }
    }

    var value: JSONValue {
        var fields: [String: JSONValue] = [:]
        if let userTurns { fields["limit"] = .int(userTurns) }
        if case .older(let older, _) = self { fields["older"] = older }
        return .object(fields)
    }
}
