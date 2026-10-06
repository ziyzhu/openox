import Foundation

nonisolated enum ModelSelectionChange: Equatable {
    case pending(ModelSelection, RunID)
    case applied(ModelSelection)
    case cancelled(ModelSelection)
    case failed(ModelSelection, String)

    var selection: ModelSelection {
        switch self {
        case let .pending(selection, _), let .applied(selection), let .cancelled(selection), let .failed(selection, _): selection
        }
    }

    var pendingSelection: ModelSelection? {
        if case .pending = self { selection } else { nil }
    }

    var status: String {
        switch self {
        case .pending: "pending"
        case .applied: "applied"
        case .cancelled: "cancelled"
        case .failed: "failed"
        }
    }

    var appInformation: JSONValue {
        .object([
            "status": .string(status),
            "selection": selection.appInformation,
            "error": {
                if case let .failed(_, message) = self { return .string(message) }
                return JSONValue.null
            }(),
        ])
    }
}

nonisolated extension ModelSelection {
    var appInformation: JSONValue {
        .object([
            "provider": .string(providerID),
            "model": .string(modelID),
            "thinkingLevel": reasoningEffort.map(JSONValue.string) ?? .null,
        ])
    }
}
