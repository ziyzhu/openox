import Foundation
import WebKit

final class LoginCapture: NSObject, WKScriptMessageHandler {
    static let channelName = "oxLoginCapture"
    static let flowChannelName = "oxLoginFlow"

    struct Value {
        let text: String
        let host: String
    }

    private var username: Value?
    private var email: Value?
    private var password: Value?
    private weak var page: Service.ServiceWebPage?
    private weak var owner: Service?
    private(set) var steps: [JSONValue] = []
    private(set) var truncated = false
    private var flowBytes = 0

    func install(on page: Service.ServiceWebPage, owner: Service, credentials: Bool) async {
        self.page = page
        self.owner = owner
        let controller = page.userContentController
        controller.add(self, contentWorld: .defaultClient, name: Self.flowChannelName)
        let flow = WKUserScript(source: Self.flowScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)
        page.additionalUserScripts.append(flow)
        controller.addUserScript(flow)
        let frames = (try? await page.discoverFrames(owner: owner)) ?? []
        for frame in frames {
            _ = try? await page.page.callJavaScript(Self.flowScript, arguments: [:], in: frame.info, contentWorld: .defaultClient)
        }
        if credentials {
            controller.removeScriptMessageHandler(forName: Self.channelName)
            controller.add(self, name: Self.channelName)
            let script = WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            page.additionalUserScripts.append(script)
            controller.addUserScript(script)
            for frame in frames {
                _ = try? await owner.evalOnce(page, frame.guarded(Self.script), timeout: 2, frame: frame.info)
            }
        }
        Log.service.info("LoginCapture.install page=\(page.logLabel)")
    }

    func remove() async {
        guard let page else { return }
        let controller = page.userContentController
        controller.removeScriptMessageHandler(forName: Self.channelName)
        controller.removeScriptMessageHandler(forName: Self.flowChannelName, contentWorld: .defaultClient)
        let sources = [Self.script, Self.flowScript]
        page.additionalUserScripts.removeAll { sources.contains($0.source) }
        let scripts = controller.userScripts.filter { !sources.contains($0.source) }
        controller.removeAllUserScripts()
        scripts.forEach(controller.addUserScript)
        let frames = if let owner { (try? await page.discoverFrames(owner: owner)) ?? [] } else { Array(page.frameTargets.values) }
        for frame in frames {
            _ = try? await page.page.callJavaScript("window.__oxLoginFlow?.stop()", arguments: [:], in: frame.info, contentWorld: .defaultClient)
            _ = try? await page.page.callJavaScript("window.__oxLoginCapture?.stop()", arguments: [:], in: frame.info, contentWorld: .page)
        }
        self.page = nil
        self.owner = nil
    }

    func discard() async {
        await remove()
        username = nil
        email = nil
        password = nil
        steps = []
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == Self.flowChannelName {
            recordStep(message)
            return
        }
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

    var trace: JSONValue {
        .object(["steps": .array(steps), "truncated": .bool(truncated)])
    }

    private func recordStep(_ message: WKScriptMessage) {
        guard page != nil, message.frameInfo.securityOrigin.protocol == "https",
              let body = message.body as? [String: Any],
              let event = body["event"] as? String,
              ["page", "focus", "click", "submit"].contains(event),
              let route = body["route"] as? String, route.count <= 256,
              let controls = body["controls"] as? [[String: Any]], controls.count <= 16 else { return }
        guard steps.count < 64 else { truncated = true; return }
        let origin = message.frameInfo.securityOrigin
        var fields: [String: JSONValue] = [
            "event": .string(event),
            "origin": .string("https://\(origin.host)\(origin.port == 0 || origin.port == 443 ? "" : ":\(origin.port)")"),
            "mainFrame": .bool(message.frameInfo.isMainFrame),
            "route": .string(route),
            "controls": .array(controls.compactMap(Self.flowControl))
        ]
        if let target = body["target"] as? [String: Any], let control = Self.flowControl(target) {
            fields["target"] = control
        }
        let step = JSONValue.object(fields)
        guard steps.last != step else { return }
        let bytes = step.jsonString().utf8.count
        guard flowBytes + bytes <= 48_000 else { truncated = true; return }
        flowBytes += bytes
        steps.append(step)
    }

    private static func flowControl(_ body: [String: Any]) -> JSONValue? {
        guard let selector = body["selector"] as? String, selector.count <= 1024,
              selector.range(of: #"^[a-z0-9*:()> \-]+$"#, options: .regularExpression) != nil,
              let kind = body["kind"] as? String,
              ["username", "password", "code", "text", "button", "link", "form", "select"].contains(kind) else { return nil }
        var result: [String: JSONValue] = ["selector": .string(selector), "kind": .string(kind)]
        if let intent = body["intent"] as? String, Self.flowIntents.contains(intent) {
            result["intent"] = .string(intent)
        }
        return .object(result)
    }

    func credential() -> (owner: String, values: [String: String])? {
        guard let password else { return nil }
        let owner = password.host
        let named = [username, email].compactMap { $0 }.first { Self.sameSite($0.host, owner) }
        guard let name = named?.text, !name.isEmpty else { return nil }
        return (owner, ["username": name, "password": password.text])
    }

    private static func sameSite(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasSuffix(".\(rhs)") || rhs.hasSuffix(".\(lhs)")
    }

    static let script = #"""
    (() => {
      if (window.__oxLoginCapture) return;
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
        try { window.webkit.messageHandlers.oxLoginCapture.postMessage({ kind: type, value: element.value }); } catch { stop(); }
      };
      const events = ["input", "change", "blur"];
      const changed = event => post(event.composedPath?.()[0] ?? event.target);
      const leaving = () => document.querySelectorAll("input[autocomplete]").forEach(post);
      const stop = () => {
        events.forEach(type => document.removeEventListener(type, changed, true));
        window.removeEventListener("pagehide", leaving, true);
        delete window.__oxLoginCapture;
      };
      events.forEach(type => document.addEventListener(type, changed, true));
      window.addEventListener("pagehide", leaving, true);
      window.__oxLoginCapture = { stop };
    })();
    """#
}
