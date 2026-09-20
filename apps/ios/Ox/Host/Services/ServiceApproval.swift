import Foundation
import WebKit

@MainActor
struct ActionApproval {
    enum Outcome {
        case approved, denied, blocked, stopped
        var isApproved: Bool { self == .approved }
    }

    struct Request: Identifiable {
        let id = UUID()
        let action: String
        let prompt: String
        let approve = L10n.string("Approve")
        let alwaysApprove = L10n.string("Always allow")
        let deny = L10n.string("Deny")
        var options: [String] { [approve, alwaysApprove, deny] }
    }

    let serviceManager: ServiceManager
    let ownerID: UUID
    var callerName: String? = nil
    var resolveService: (String) -> Service? = { _ in nil }

    func request(
        action: String,
        defaultPolicy: ActionPolicy,
        args: Any? = nil,
        prompt override: String? = nil,
        choose: (Request) async -> String?
    ) async -> Outcome {
        guard !Task.isCancelled else { return .stopped }
        switch serviceManager.actionPolicy(for: action, default: defaultPolicy) {
        case .allow:
            Log.service.info("ActionApproval.allow action=\(action) caller=\(ownerID)")
            return .approved
        case .block:
            Log.service.info("ActionApproval.block action=\(action) caller=\(ownerID)")
            return .blocked
        case .ask:
            break
        }
        let display = approvalLabel(for: action)
        let details = Self.approvalDetails(args)
        var prompt = override ?? (details.isEmpty ? display : "\(display)\n\(details)")
        if override == nil, action == Actions.appLogs {
            prompt = "\(display)\n\(L10n.string("Logs may include private data from other chats and Profiles and become available to the current model. Always allow applies to all app logs."))"
        } else if override == nil, action == "ios:browser:exportPdf" {
            let page = serviceManager.browserActionSessions.existingSession(for: ownerID)?.webPage
            let destination = page?.url?.host(percentEncoded: false) ?? L10n.string("Current page")
            let savesArtifact = (args as? [String: Any])?["filename"] is String
            let disclosure = savesArtifact
                ? L10n.string("The exported PDF may include signed-in or sensitive information beyond the visible area, is saved to the current Profile as an artifact, and becomes available to the current model. Always allow applies to every page Browser visits.")
                : L10n.string("The exported PDF may include signed-in or sensitive information beyond the visible area and becomes available to the current model. Always allow applies to every page Browser visits.")
            prompt = "\(display) - \(destination)\n\(disclosure)"
        } else if override == nil, ["ios:browser:executeScript", "ios:browser:injectScript", "ios:browser:startCapture"].contains(action) {
            let page = serviceManager.browserActionSessions.existingSession(for: ownerID)?.webPage
            let destination = page?.url?.host(percentEncoded: false) ?? L10n.string("Current page")
            prompt = "\(display) - \(destination)\n\(L10n.string("Dangerous mode gives the agent full control of this website, including signed-in data and network access. Always allow applies to every page Web visits."))"
        }
        if let callerName { prompt += "\n\(callerName)" }
        let request = Request(action: action, prompt: prompt)
        guard let answer = await choose(request), !Task.isCancelled else { return .stopped }
        Log.service.info("ActionApproval.answer action=\(action) caller=\(ownerID) answer=\(answer)")
        if answer == request.alwaysApprove {
            serviceManager.setActionPolicy(.allow, for: action)
            return .approved
        }
        return answer == request.approve ? .approved : .denied
    }

    private static func approvalDetails(_ args: Any?) -> String {
        guard let args, !(args is NSNull) else { return "" }
        guard let dict = args as? [String: Any] else { return approvalValue(args) }
        return dict.keys.sorted()
            .compactMap { key -> String? in
                guard let value = dict[key] else { return nil }
                let text = approvalValue(value)
                return text.isEmpty ? nil : "\(key): \(text)"
            }
            .joined(separator: "\n")
    }

    private static func approvalValue(_ value: Any) -> String {
        switch value {
        case is NSNull: return ""
        case let s as String: return clip(s)
        case let n as NSNumber: return n.stringValue
        case let arr as [Any]: return clip(arr.map { approvalValue($0) }.joined(separator: ", "))
        case let dict as [String: Any]:
            return clip(dict.keys.sorted().compactMap { key in
                guard let v = dict[key] else { return nil }
                let text = approvalValue(v)
                return text.isEmpty ? nil : "\(key): \(text)"
            }.joined(separator: ", "))
        default: return clip(String(describing: value))
        }
    }

    private static func clip(_ value: String, _ max: Int = 140) -> String {
        value.count > max ? String(value.prefix(max)) + "…" : value
    }

    private func approvalLabel(for action: String) -> String {
        if let label = Actions.label(for: action) {
            return Self.approvalTitle(label)
        }
        guard let separator = action.lastIndex(of: ":") else { return action }
        let qualifiedDomain = String(action[..<separator])
        let domain = qualifiedDomain.hasPrefix("web:") || qualifiedDomain.hasPrefix("api:") || qualifiedDomain.hasPrefix("mcp:")
            ? String(qualifiedDomain.dropFirst(4)) : qualifiedDomain
        let actionID = String(action[action.index(after: separator)...])
        guard let service = resolveService(domain) ?? serviceManager.service(domain: domain) else {
            return action
        }
        return "\(service.title) - \(service.actionLabel(for: actionID) ?? actionID)"
    }

    private static func approvalTitle(_ label: String) -> String {
        guard let separator = label.firstIndex(of: ":") else { return label }
        let service = label[..<separator].trimmingCharacters(in: .whitespaces)
        let action = label[label.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        return "\(service) - \(action)"
    }

}
