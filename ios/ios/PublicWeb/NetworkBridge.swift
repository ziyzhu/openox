import Foundation
import WebKit

enum NetworkBridge: WebViewBridge {
    static let channelName = "oxNetwork"

    static func handle(message: WKScriptMessage, tag: String) {
        let body = message.body as? [String: Any] ?? [:]
        let via = body["via"] as? String ?? "?"
        let method = body["method"] as? String ?? "?"
        let url = body["url"] as? String ?? "?"
        if let err = body["error"] as? String {
            Log.webView.error("NetworkBridge domain=\(tag) via=\(via) \(method) \(LogPrivacy.url(url)) -> \(LogPrivacy.text(err))")
        } else if let status = body["status"] as? Int {
            Log.webView.warning("NetworkBridge domain=\(tag) via=\(via) \(method) \(LogPrivacy.url(url)) -> \(status)")
        }
    }

    static let js: String = #"""
    (() => {
      const post = (body) => {
        try { window.webkit?.messageHandlers?.oxNetwork?.postMessage(body); } catch {}
      };

      const origFetch = window.fetch?.bind(window);
      if (origFetch) {
        window.fetch = async (input, init) => {
          const url = typeof input === 'string' ? input : (input?.url ?? String(input));
          const method = (init?.method || (typeof input === 'object' && input?.method) || 'GET').toUpperCase();
          let res;
          try {
            res = await origFetch(input, init);
          } catch (e) {
            post({ via: 'fetch', method, url, error: e?.message ?? String(e) });
            throw e;
          }
          if (!res.ok) post({ via: 'fetch', method, url, status: res.status });
          return res;
        };
      }

      const XHR = window.XMLHttpRequest;
      if (XHR) {
        const origOpen = XHR.prototype.open;
        const origSend = XHR.prototype.send;
        XHR.prototype.open = function (method, url, ...rest) {
          this.__networkRequest = { method: String(method || 'GET').toUpperCase(), url: String(url) };
          return origOpen.call(this, method, url, ...rest);
        };
        XHR.prototype.send = function (...args) {
          const info = this.__networkRequest || { method: '?', url: '?' };
          this.addEventListener('error', () => {
            post({ via: 'xhr', method: info.method, url: info.url, error: 'network error' });
          });
          this.addEventListener('load', () => {
            if (this.status >= 400) post({ via: 'xhr', method: info.method, url: info.url, status: this.status });
          });
          return origSend.apply(this, args);
        };
      }
    })();
    """#
}
