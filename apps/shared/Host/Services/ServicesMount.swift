import Foundation

nonisolated enum ServicesMount {
    enum Kind: String, CaseIterable, Sendable {
        case web
        case api
        case iOS = "ios"
        case mcp

        var repositoryKind: Repository.ServiceKind {
            switch self {
            case .web: .web
            case .api: .api
            case .iOS: .iOS
            case .mcp: .mcp
            }
        }
    }
}
