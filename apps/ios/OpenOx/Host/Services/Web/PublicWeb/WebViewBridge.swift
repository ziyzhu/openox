import Foundation
import WebKit

protocol WebViewBridge {
    static var channelName: String { get }
    static var js: String { get }
    static func handle(message: WKScriptMessage, tag: String)
}

extension WebViewBridge {
    static func userScript() -> WKUserScript {
        WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}

enum WebViewBridges {
    static let all: [WebViewBridge.Type] = [ConsoleBridge.self, NetworkBridge.self]

    static func handle(message: WKScriptMessage, tag: String) {
        all.first { $0.channelName == message.name }?.handle(message: message, tag: tag)
    }
}

extension WKUserContentController {
    func installBridgeHandlers(_ handler: WKScriptMessageHandler) {
        for bridge in WebViewBridges.all {
            add(handler, name: bridge.channelName)
        }
    }

    func addBridgeUserScripts() {
        WebViewBridges.all.forEach { addUserScript($0.userScript()) }
    }
}
