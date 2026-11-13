import Foundation
import WebKit

enum SecretRequestGuard {
    private static var lists: [String: WKContentRuleList] = [:]
    private static var installed: [ObjectIdentifier: WKContentRuleList] = [:]

    static func install(on page: BrowserSession, owner: String) async {
        guard installed[ObjectIdentifier(page)] == nil,
              let domain = owner.split(separator: ":", maxSplits: 1).last.map(String.init),
              let list = await ruleList(for: domain) else { return }
        page.userContentController.add(list)
        installed[ObjectIdentifier(page)] = list
        Log.service.info("SecretRequestGuard.install page=\(page.logLabel) domain=\(domain)")
    }

    static func remove(from page: BrowserSession) {
        guard let list = installed.removeValue(forKey: ObjectIdentifier(page)) else { return }
        page.userContentController.remove(list)
        Log.service.info("SecretRequestGuard.remove page=\(page.logLabel)")
    }

    private static func ruleList(for domain: String) async -> WKContentRuleList? {
        if let list = lists[domain] { return list }
        let escaped = NSRegularExpression.escapedPattern(for: domain)
        let rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*", "load-type": ["third-party"], "resource-type": ["fetch", "ping"]],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": "^https?://([^/]+\\.)?\(escaped)[:/]"],
             "action": ["type": "ignore-previous-rules"]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let encoded = String(data: data, encoding: .utf8) else { return nil }
        do {
            let list = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "ox-secret-\(domain)", encodedContentRuleList: encoded)
            lists[domain] = list
            return list
        } catch {
            Log.service.error("SecretRequestGuard.compile domain=\(domain) error=\(error.localizedDescription)")
            return nil
        }
    }
}
