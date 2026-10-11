import Foundation
import WebKit

enum ConsoleBridge: WebViewBridge {
    static let channelName = "oxConsole"

    static func handle(message: WKScriptMessage, tag: String) {
        let body = message.body as? [String: Any] ?? [:]
        let level = body["level"] as? String ?? "log"
        let msg = LogPrivacy.text(body["msg"] as? String ?? "")
        switch level {
        case "error": Log.webView.error("ConsoleBridge domain=\(tag) \(msg)")
        case "warn":  Log.webView.warning("ConsoleBridge domain=\(tag) \(msg)")
        default:      Log.webView.debug("ConsoleBridge domain=\(tag) \(msg)")
        }
    }

    static let js: String = #"""
    (() => {
      const post = (level, args) => {
        try {
          const msg = args.map(a => {
            if (typeof a === 'string') return a;
            try { return JSON.stringify(a); } catch { return String(a); }
          }).join(' ');
          window.webkit?.messageHandlers?.oxConsole?.postMessage({ level, msg });
        } catch {}
      };
      for (const level of ['log','warn','error','info','debug']) {
        const orig = console[level]?.bind(console);
        console[level] = (...args) => { post(level, args); orig?.(...args); };
      }
      window.addEventListener('error', (e) => {
        post('error', ['[uncaught]', e.message, (e.filename || '') + ':' + (e.lineno || 0)]);
      });
      window.addEventListener('unhandledrejection', (e) => {
        post('error', ['[unhandled rejection]', e.reason?.message ?? String(e.reason)]);
      });
    })();
    """#
}
