import Foundation
import WebKit

nonisolated struct PermissionPresentation: Codable, Equatable, Sendable {
    let title: String
    let purpose: String?
    let disclosure: String?
    let arguments: String?

    init(title: String, purpose: String? = nil, disclosure: String? = nil, arguments: String? = nil) {
        self.title = title
        self.purpose = Self.nonempty(purpose)
        self.disclosure = Self.nonempty(disclosure)
        self.arguments = Self.nonempty(arguments)
    }

    init(prompt: String) {
        let lines = prompt
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        title = lines.first ?? prompt
        purpose = Self.nonempty(lines.dropFirst().joined(separator: "\n"))
        disclosure = nil
        arguments = nil
    }

    var message: String? {
        let parts = [purpose, disclosure].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    var prompt: String {
        [title, message].compactMap { $0 }.joined(separator: "\n")
    }

    private static func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
struct ActionApproval {
    enum Outcome {
        case approved, denied, blocked, stopped
        var isApproved: Bool { self == .approved }
    }

    struct Request: Identifiable {
        let id = UUID()
        let action: String
        let presentation: PermissionPresentation
        let approve = L10n.string("Approve")
        let alwaysApprove = L10n.string("Always allow")
        let deny = L10n.string("Deny")
        var prompt: String { presentation.prompt }
        var requiresExplicitApproval: Bool { action == Actions.chatDelete }
        var options: [String] { requiresExplicitApproval ? [approve, deny] : [approve, alwaysApprove, deny] }
    }

    let serviceManager: ServiceManager
    let ownerID: UUID
    var callerName: String? = nil
    var resolveService: (String) -> Service? = { _ in nil }

    func request(
        action: String,
        defaultPolicy: ActionPolicy,
        args: Any? = nil,
        purpose: String? = nil,
        prompt override: String? = nil,
        choose: (Request) async -> String?
    ) async -> Outcome {
        guard !Task.isCancelled else { return .stopped }
        switch serviceManager.actionPolicy(for: action, default: defaultPolicy) {
        case .allow where action != Actions.chatDelete:
            Log.service.info("ActionApproval.allow action=\(action) caller=\(ownerID)")
            return .approved
        case .block:
            Log.service.info("ActionApproval.block action=\(action) caller=\(ownerID)")
            return .blocked
        case .ask, .allow:
            break
        }
        let display = approvalLabel(for: action)
        let overridePresentation = override.map(PermissionPresentation.init(prompt:))
        var title = overridePresentation?.title ?? display
        var disclosure = overridePresentation?.message
        if override == nil, action == Actions.appLogs {
            disclosure = L10n.string("Logs may include private data from other chats and Profiles and become available to the current model. Always allow applies to all app logs.")
        } else if override == nil, action == "ox.web.browser.exportPdf" {
            let page = serviceManager.browserActionSessions.existingSession(for: ownerID)?.webPage
            let destination = page?.url?.host(percentEncoded: false) ?? L10n.string("Current page")
            let savesArtifact = (args as? [String: Any])?["filename"] is String
            title = "\(display) - \(destination)"
            disclosure = savesArtifact
                ? L10n.string("The exported PDF may include signed-in or sensitive information beyond the visible area, is saved to the current Profile as an artifact, and becomes available to the current model. Always allow applies to every page Browser visits.")
                : L10n.string("The exported PDF may include signed-in or sensitive information beyond the visible area and becomes available to the current model. Always allow applies to every page Browser visits.")
        } else if override == nil, [
            "ox.web.browser.executeScript",
            "ox.web.browser.injectScript",
            "ox.web.browser.startCapture",
        ].contains(action) {
            let page = serviceManager.browserActionSessions.existingSession(for: ownerID)?.webPage
            let destination = page?.url?.host(percentEncoded: false) ?? L10n.string("Current page")
            title = "\(display) - \(destination)"
            disclosure = L10n.string("Dangerous mode gives the agent full control of this website, including signed-in data and network access. Always allow applies to every page Web visits.")
        }
        if let callerName {
            disclosure = [disclosure, callerName].compactMap { $0 }.joined(separator: "\n")
        }
        let request = Request(
            action: action,
            presentation: PermissionPresentation(
                title: title,
                purpose: purpose,
                disclosure: disclosure,
                arguments: Self.approvalArguments(args)
            )
        )
        guard let answer = await choose(request), !Task.isCancelled else { return .stopped }
        Log.service.info("ActionApproval.answer action=\(action) caller=\(ownerID) answer=\(answer)")
        if answer == request.alwaysApprove, !request.requiresExplicitApproval {
            serviceManager.setActionPolicy(.allow, for: action)
            return .approved
        }
        return answer == request.approve ? .approved : .denied
    }

    private static func approvalArguments(_ args: Any?) -> String? {
        guard let args, !(args is NSNull) else { return nil }
        if let dict = args as? [String: Any], dict.isEmpty { return nil }
        if let array = args as? [Any], array.isEmpty { return nil }
        guard JSONSerialization.isValidJSONObject(args),
              let data = try? JSONSerialization.data(
                withJSONObject: args,
                options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys]
              ) else {
            return String(describing: args)
        }
        return String(data: data, encoding: .utf8)
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
