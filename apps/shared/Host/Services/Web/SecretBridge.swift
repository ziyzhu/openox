import Foundation
import WebKit

final class SecretBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let channelName = "oxSecret"

    private weak var service: Service?
    private weak var page: Service.ServiceWebPage?

    init(service: Service, page: Service.ServiceWebPage) {
        self.service = service
        self.page = page
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let service, let page, let attempt = page.secretAttempt else {
            return (nil, "No secret is available to this page.")
        }
        let host = message.frameInfo.securityOrigin.host
        let reference = JSONValue.from(message.body).objectValue?["ref"] ?? .null
        do {
            let value = try await attempt.retrieve(reference, caller: service.definition.actionNamespace, host: host)
            await SecretRequestGuard.install(on: page, owner: service.definition.actionNamespace)
            attempt.keepRendering(page)
            return (value.toAny(), nil)
        } catch {
            Log.service.error("SecretBridge.retrieve domain=\(service.domain) host=\(host) error=\(error.localizedDescription)")
            return (nil, error.localizedDescription)
        }
    }
}
