import Foundation
import WebKit

final class SecretBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let channelName = "oxSecret"

    private weak var page: BrowserSession?

    init(page: BrowserSession) {
        self.page = page
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let page, let attempt = page.secretAttempt, let context = page.frameSecretContext else {
            return (nil, "No secret is available to this page.")
        }
        let caller = context.service
        let body = JSONValue.from(message.body).objectValue
        if body?["documentID"]?.stringValue != context.documentID {
            return (nil, "Secret request came from another frame document.")
        }
        guard message.frameInfo.securityOrigin.protocol == "https" else {
            return (nil, "Secret retrieval requires a secure origin.")
        }
        let host = message.frameInfo.securityOrigin.host
        let reference = body?["ref"] ?? .null
        do {
            let value = try await attempt.retrieve(reference, caller: caller.definition.actionNamespace, host: host)
            await SecretRequestGuard.install(on: page, owner: caller.definition.actionNamespace)
            attempt.keepRendering(page)
            return (value.toAny(), nil)
        } catch {
            Log.service.error("SecretBridge.retrieve domain=\(caller.domain) host=\(host) error=\(error.localizedDescription)")
            return (nil, error.localizedDescription)
        }
    }
}
