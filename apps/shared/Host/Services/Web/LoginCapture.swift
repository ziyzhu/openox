import Foundation
import WebKit

final class LoginCapture: NSObject, WKScriptMessageHandler {
    static let channelName = "oxLoginCapture"

    struct Value {
        let text: String
        let host: String
    }

    private var username: Value?
    private var email: Value?
    private var password: Value?
    private weak var page: Service.ServiceWebPage?

    func install(on page: Service.ServiceWebPage) async {
        self.page = page
        let controller = page.userContentController
        controller.removeScriptMessageHandler(forName: Self.channelName)
        controller.add(self, name: Self.channelName)
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        _ = try? await page.page.callJavaScript(Self.script, arguments: [:], in: nil, contentWorld: .page)
        Log.service.info("LoginCapture.install page=\(page.logLabel)")
    }

    func remove() {
        page?.userContentController.removeScriptMessageHandler(forName: Self.channelName)
        page = nil
    }

    func discard() {
        remove()
        username = nil
        email = nil
        password = nil
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let kind = body["kind"] as? String,
              let text = body["value"] as? String, !text.isEmpty, text.count <= 1024 else { return }
        let value = Value(text: text, host: message.frameInfo.securityOrigin.host.lowercased())
        switch kind {
        case "username": username = value
        case "email": email = value
        case "password": password = value
        default: return
        }
    }

    func credential(fallbackUsername: String?) -> (owner: String, values: [String: String])? {
        guard let password else { return nil }
        let owner = password.host
        let named = [username, email].compactMap { $0 }.first { Self.sameSite($0.host, owner) }
        guard let name = named?.text ?? fallbackUsername, !name.isEmpty else { return nil }
        return (owner, ["username": name, "password": password.text])
    }

    private static func sameSite(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasSuffix(".\(rhs)") || rhs.hasSuffix(".\(lhs)")
    }

    static let script = #"""
    (() => {
      if (window.__oxLoginCapture) return;
      window.__oxLoginCapture = true;
      const kind = element => {
        if (!(element instanceof HTMLInputElement)) return null;
        const tokens = (element.getAttribute("autocomplete") || "").toLowerCase().split(/\s+/);
        if (tokens.includes("current-password")) return "password";
        if (tokens.includes("username")) return "username";
        if (tokens.includes("email")) return "email";
        return null;
      };
      const post = element => {
        const type = kind(element);
        if (!type || !element.value) return;
        try { window.webkit.messageHandlers.oxLoginCapture.postMessage({ kind: type, value: element.value }); } catch {}
      };
      for (const type of ["input", "change", "blur"]) {
        document.addEventListener(type, event => post(event.composedPath?.()[0] ?? event.target), true);
      }
      window.addEventListener("pagehide", () => document.querySelectorAll("input[autocomplete]").forEach(post), true);
    })();
    """#
}
