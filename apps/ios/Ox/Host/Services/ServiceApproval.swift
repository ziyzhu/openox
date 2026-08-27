import Foundation
import WebKit

@MainActor
struct ServiceApproval {
    enum Outcome {
        case approved, denied, stopped
        var isApproved: Bool { self == .approved }
    }

    struct Request: Identifiable {
        let id = UUID()
        let action: String
        let prompt: String
        let approve = L10n.string("Approve")
        let alwaysApprove = L10n.string("Always approve")
        let deny = L10n.string("Deny")
        var options: [String] { [approve, alwaysApprove, deny] }
    }

    let serviceManager: ServiceManager
    let ownerID: UUID
    var callerName: String? = nil
    var resolveService: (String) -> Service? = { _ in nil }

    func request(
        action: String,
        args: Any? = nil,
        prompt override: String? = nil,
        choose: (Request) async -> String?
    ) async -> Outcome {
        guard !Task.isCancelled else { return .stopped }
        if serviceManager.shouldAutoApprove(action) {
            Log.service.info("ServiceApproval.auto action=\(action) caller=\(ownerID)")
            return .approved
        }
        let display = approvalLabel(for: action)
        let details = Self.approvalDetails(args)
        var prompt = override ?? (details.isEmpty ? display : "\(display)\n\(details)")
        if override == nil, action == "ios:browser:screenshot" {
            let page = serviceManager.browserActionSessions.existingSession(for: ownerID)?.webPage
            let destination = page?.url?.host(percentEncoded: false) ?? L10n.string("Current page")
            let savesArtifact = (args as? [String: Any])?["filename"] is String
            let disclosure = savesArtifact
                ? L10n.string("The full-page screenshot may include signed-in or sensitive information beyond the visible area, is saved to the current Profile as an artifact, and becomes available to the current model. Always approve applies to every page Browser visits.")
                : L10n.string("The full-page screenshot may include signed-in or sensitive information beyond the visible area and becomes available to the current model. Always approve applies to every page Browser visits.")
            prompt = "\(display) - \(destination)\n\(disclosure)"
        } else if override == nil, ["ios:browser:executeJavaScript", "ios:browser:injectScript", "ios:browser:startCapture"].contains(action) {
            let page = serviceManager.browserActionSessions.existingSession(for: ownerID)?.webPage
            let destination = page?.url?.host(percentEncoded: false) ?? L10n.string("Current page")
            prompt = "\(display) - \(destination)\n\(L10n.string("Dangerous mode gives the agent full control of this website, including signed-in data and network access. Always approve applies to every page Web visits."))"
        }
        if let callerName { prompt += "\n\(callerName)" }
        let request = Request(action: action, prompt: prompt)
        guard let answer = await choose(request), !Task.isCancelled else { return .stopped }
        Log.service.info("ServiceApproval.answer action=\(action) caller=\(ownerID) answer=\(answer)")
        if answer == request.alwaysApprove {
            serviceManager.setAutoApprove(action, true)
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
        if let invocation = InvocationName(rawValue: action) {
            return Self.approvalTitle(invocation.approvalLabel)
        }
        guard let separator = action.lastIndex(of: ":") else { return action }
        let qualifiedDomain = String(action[..<separator])
        let domain = qualifiedDomain.hasPrefix("web:") || qualifiedDomain.hasPrefix("mcp:")
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
