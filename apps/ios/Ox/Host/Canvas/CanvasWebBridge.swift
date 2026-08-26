import Foundation
import WebKit

@MainActor
final class CanvasWebBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let documentURL = URL(string: "ox-artifact:///")!

    static func isDocumentURL(_ url: URL) -> Bool {
        if url.absoluteString == "about:blank" { return true }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        components.fragment = nil
        return components.url == documentURL
    }

    private let canvas: OxCanvas

    init(canvas: OxCanvas) {
        self.canvas = canvas
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        Task { @MainActor in
            do {
                guard message.frameInfo.isMainFrame,
                      let url = message.frameInfo.request.url,
                      Self.isDocumentURL(url),
                      let body = message.body as? [String: Any],
                      body["documentID"] as? String == canvas.id.uuidString,
                      let function = body["function"] as? String,
                      let arguments = body["arguments"] as? [String: Any],
                      JSONSerialization.isValidJSONObject(arguments) else {
                    throw RuntimeError.bridge("Invalid canvas service request")
                }
                let data = try JSONSerialization.data(withJSONObject: arguments)
                guard data.count <= 1_048_576 else { throw RuntimeError.bridge("Canvas request exceeds 1 MiB") }
                let value = try JSONDecoder().decode(JSONValue.self, from: data)
                let result = try await canvas.call(function: function, arguments: value)
                replyHandler(["ok": true, "value": result?.toAny() ?? NSNull()], nil)
            } catch {
                Log.service.error("Canvas.bridge rejected caller=\(canvas.id) error=\(error.localizedDescription)")
                replyHandler(["ok": false, "error": error.localizedDescription], nil)
            }
        }
    }
}
