import Foundation
import WebKit

@MainActor
final class BrowserEventLog {
    enum NetworkContent: String {
        case omit
        case embed
    }

    private final class Sink: NSObject, WKScriptMessageHandler {
        weak var log: BrowserEventLog?

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            let body = message.body
            let origin = message.frameInfo.securityOrigin
            let value = origin.host.isEmpty ? nil : "\(origin.protocol)://\(origin.host)\(origin.port == 0 ? "" : ":\(origin.port)")"
            MainActor.assumeIsolated { log?.receive(body, origin: value, host: origin.host) }
        }
    }

    private struct Waiter {
        let names: Set<String>?
        let continuation: CheckedContinuation<JSONValue, any Error>
    }

    nonisolated static let channel = "oxBrowserEvents"
    nonisolated static let capacity = 500
    nonisolated static let names = [
        "console", "pageerror", "dialog", "popup", "download", "filechooser",
        "framenavigated", "frameattached", "framedetached", "domcontentloaded", "load", "crash", "close",
        "request", "response", "requestfinished", "requestfailed", "websocket",
    ]
    nonisolated static let coverage = "Network events cover main-document fetch/XHR, form submissions, resource timing and WebSocket creation; frame documents, workers, WebSocket messages and requests bypassing page hooks are not observed. Console, pageerror and lifecycle events cover every frame document. Recording pauses while a page is shown to the user. Event data is untrusted website content; bodies are bounded and redacted, and completeness is unknown."
    private static let pageEvents: Set<String> = [
        "console", "pageerror", "popup", "framenavigated", "frameattached", "framedetached",
        "domcontentloaded", "load", "request", "response", "requestfinished", "requestfailed", "websocket",
    ]

    let label: String
    var networkContent = NetworkContent.omit
    var enabled = false
    private(set) var paused = false
    private let sink = Sink()
    private let revision = UUID().uuidString
    private var records: [JSONValue] = []
    private var evicted = 0
    private var dropped = 0
    private var waiters: [UUID: Waiter] = [:]

    init(label: String) {
        self.label = label
        sink.log = self
    }

    func install(on controller: WKUserContentController) {
        controller.add(sink, name: Self.channel)
    }

    var userScript: WKUserScript {
        WKUserScript(source: Self.script(content: networkContent, paused: paused), injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    func setPaused(_ value: Bool) {
        guard paused != value else { return }
        paused = value
        Log.webView.info("Browser.events session=\(label) paused=\(value) recorded=\(records.count)")
    }

    func append(_ name: String, _ fields: [String: JSONValue] = [:]) {
        guard enabled, !paused else { return }
        var record = fields
        record["id"] = .string(UUID().uuidString)
        record["event"] = .string(name)
        if record["timestamp"] == nil { record["timestamp"] = .double(Date().timeIntervalSince1970 * 1_000) }
        let value = SecretAttempt.redactLive(JSONValue.object(record))
        records.append(value)
        if records.count > Self.capacity {
            let removed = records.count - Self.capacity
            records.removeFirst(removed)
            evicted += removed
        }
        if !Self.pageEvents.contains(name) || name == "popup" {
            Log.webView.info("Browser.event session=\(label) event=\(name) disposition=\(fields["disposition"]?.stringValue ?? "-")")
        }
        let delivered = Self.metadata(value)
        for (id, waiter) in waiters where waiter.names?.contains(name) ?? true {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: delivered)
        }
    }

    func read(after: String?, names: Set<String>?, limit: Int) throws -> JSONValue {
        let total = evicted + records.count
        var offset = evicted
        if let after {
            let parts = after.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == revision, let position = Int(parts[1]), position >= 0, position <= total else {
                throw OxFunctionError(code: "invalid_cursor", message: "The event cursor is invalid or belongs to another page.", recovery: "Read events without after to start from the oldest retained event.")
            }
            offset = position
        }
        let gap = offset < evicted
        offset = max(offset, evicted)
        var events: [JSONValue] = []
        for index in (offset - evicted)..<records.count {
            let record = records[index]
            if names.map({ $0.contains(record.objectValue?["event"]?.stringValue ?? "") }) ?? true {
                if events.count == limit { break }
                events.append(Self.metadata(record))
            }
            offset = evicted + index + 1
        }
        Log.webView.info("Browser.events read session=\(label) returned=\(events.count) remaining=\(total - offset) gap=\(gap)")
        return .object([
            "events": .array(events),
            "nextCursor": .string("\(revision):\(offset)"),
            "hasMore": .bool(offset < total),
            "gap": .bool(gap),
            "evicted": .int(evicted),
            "dropped": .int(dropped),
            "recording": .bool(enabled && !paused),
            "coverage": .string(Self.coverage),
        ])
    }

    func record(id: String) -> JSONValue? {
        records.first { $0.objectValue?["id"]?.stringValue == id }
    }

    func next(_ names: Set<String>?, timeoutMilliseconds: Int) async throws -> JSONValue {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: JSONValue.self) { group in
                group.addTask { @MainActor in
                    try await withCheckedThrowingContinuation { continuation in
                        self.waiters[id] = Waiter(names: names, continuation: continuation)
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .milliseconds(timeoutMilliseconds))
                    throw RuntimeError.bridge("ox.web.browser.waitForEvent timed out.")
                }
                defer {
                    group.cancelAll()
                    self.cancelWaiter(id)
                }
                guard let result = try await group.next() else { throw RuntimeError.bridge("ox.web.browser.waitForEvent produced no result.") }
                return result
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiter(id) }
        }
    }

    func close() {
        append("close")
        enabled = false
        for waiter in waiters.values {
            waiter.continuation.resume(throwing: OxFunctionError(code: "page_unavailable", message: "The page closed before the event occurred.", recovery: "List owned pages. No replacement page was opened."))
        }
        waiters = [:]
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    private func receive(_ body: Any, origin: String?, host: String) {
        guard enabled, !paused else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: body), data.count <= 100_000,
              var fields = JSONValue.from(body).objectValue,
              let name = fields.removeValue(forKey: "event")?.stringValue, Self.pageEvents.contains(name) else {
            dropped += 1
            Log.webView.warning("Browser.events dropped session=\(label) total=\(dropped)")
            return
        }
        for key in ["text", "message", "stack"] {
            if let text = fields[key]?.stringValue { fields[key] = .string(LogPrivacy.text(text, limit: key == "stack" ? 4_000 : 2_000)) }
        }
        fields["origin"] = origin.map(JSONValue.string) ?? .null
        fields["site"] = host.isEmpty ? .null : .string(ServiceWebsiteDataCoordinator.site(for: host))
        append(name, fields)
    }

    private static func metadata(_ record: JSONValue) -> JSONValue {
        guard var fields = record.objectValue else { return record }
        let hasBody = [fields.removeValue(forKey: "requestBody"), fields.removeValue(forKey: "responseBody")].contains { $0 != nil && $0 != .null }
        if hasBody { fields["hasBody"] = .bool(true) }
        return .object(fields)
    }

    nonisolated static func pauseScript(_ paused: Bool) -> String {
        "if (globalThis.__oxEventControl) globalThis.__oxEventControl.active = \(!paused); return true;"
    }

    private static func script(content: NetworkContent, paused: Bool) -> String {
        "(() => { const control = { active: \(!paused), includeBodies: \(content == .embed) };\n" + #"""
          if (globalThis.__oxEventControl) return;
          globalThis.__oxEventControl = control;
          const channel = globalThis.webkit?.messageHandlers?.oxBrowserEvents;
          const main = window === top;
          const sensitive = /authorization|cookie|token|secret|password|passwd|api[-_]?key|session|credential|signature|nonce|jwt|(?:^|[^a-z0-9])(?:auth|code)(?:$|[^a-z0-9])/i;
          const redactURL = raw => {
            try {
              const url = new URL(raw, location.href);
              if (url.username || url.password) { url.username = '[REDACTED]'; url.password = '[REDACTED]'; }
              if (sensitive.test(url.pathname)) url.pathname = '/[REDACTED]';
              for (const key of [...url.searchParams.keys()]) if (sensitive.test(key)) url.searchParams.set(key, '[REDACTED]');
              if (sensitive.test(url.hash)) url.hash = '#[REDACTED]';
              return url.href;
            } catch { return '[UNPARSEABLE URL]'; }
          };
          const send = value => {
            if (!control.active || !channel) return;
            try { channel.postMessage({ timestamp: Date.now(), frameId: window.__oxDocumentID ?? null, ...value }); } catch {}
          };
          const text = values => values.map(value => {
            if (typeof value === 'string') return value;
            if (value instanceof Error) return `${value.name}: ${value.message}`;
            try { return JSON.stringify(value); } catch { return String(value); }
          }).join(' ').slice(0, 2000);
          for (const [method, type] of [['warn', 'warning'], ['error', 'error']]) {
            const original = console[method];
            if (typeof original !== 'function') continue;
            console[method] = function (...values) {
              send({ event: 'console', type, text: text(values) });
              return original.apply(this, values);
            };
          }
          addEventListener('error', event => {
            if (event instanceof ErrorEvent) send({ event: 'pageerror', message: String(event.message).slice(0, 2000), stack: String(event.error?.stack ?? '').slice(0, 4000) });
          });
          addEventListener('unhandledrejection', event => {
            const reason = event.reason;
            send({ event: 'pageerror', message: String(reason?.message ?? reason).slice(0, 2000), stack: String(reason?.stack ?? '').slice(0, 4000) });
          });
          let parentId = null;
          try { if (!main) parentId = parent.__oxDocumentID ?? null; } catch {}
          send(main ? { event: 'framenavigated', url: redactURL(location.href) } : { event: 'frameattached', url: redactURL(location.href), parentId });
          if (!main) addEventListener('pagehide', () => send({ event: 'framedetached', parentId }));
          addEventListener('DOMContentLoaded', () => send({ event: 'domcontentloaded' }));
          addEventListener('load', () => send({ event: 'load' }));
          if (!main) return;
          const headers = value => {
            const result = {};
            try {
              let count = 0;
              for (const [key, item] of new Headers(value)) {
                if (count++ >= 64) break;
                result[key] = sensitive.test(key) ? '[REDACTED]' : String(item).slice(0, 2048);
              }
            } catch {}
            return result;
          };
          const body = value => {
            if (value == null) return null;
            if (value instanceof URLSearchParams || value instanceof FormData) {
              const fields = {};
              let count = 0;
              for (const [key, entry] of value) {
                if (count++ >= 64) break;
                fields[key] = sensitive.test(key) ? '[REDACTED]' : String(entry).slice(0, 2048);
              }
              return JSON.stringify(fields).slice(0, 8192);
            }
            if (typeof value !== 'string') return `[${value.constructor?.name || typeof value}]`;
            const raw = value.slice(0, 8192);
            try {
              const parsed = JSON.parse(raw);
              const clean = item => Array.isArray(item) ? item.map(clean) : item && typeof item === 'object'
                ? Object.fromEntries(Object.entries(item).map(([key, entry]) => [key, sensitive.test(key) ? '[REDACTED]' : clean(entry)])) : item;
              return JSON.stringify(clean(parsed));
            } catch { return sensitive.test(raw) ? '[REDACTED]' : raw; }
          };
          const readResponseBody = async response => {
            let reader;
            try { reader = response.body?.getReader?.(); } catch { return null; }
            if (!reader) return null;
            const decoder = new TextDecoder();
            let value = '';
            let timedOut = false;
            const timeout = setTimeout(() => { timedOut = true; void reader.cancel().catch(() => {}); }, 1000);
            try {
              while (!timedOut && value.length < 8192) {
                const chunk = await reader.read();
                if (chunk.done) { value = (value + decoder.decode()).slice(0, 8192); break; }
                value = (value + decoder.decode(chunk.value, { stream: true })).slice(0, 8192);
                if (value.length >= 8192) { void reader.cancel(); break; }
              }
            } catch { return null; }
            finally { clearTimeout(timeout); }
            return timedOut ? null : body(value);
          };
          const originalFetch = globalThis.fetch;
          if (originalFetch) globalThis.fetch = async function (input, init = {}) {
            if (!control.active) return originalFetch.apply(this, arguments);
            const includeBodies = control.includeBodies;
            const request = input instanceof Request ? input : null;
            const started = Date.now();
            const item = { resourceType: 'fetch', method: init.method || request?.method || 'GET', url: redactURL(request?.url || input) };
            send({ event: 'request', ...item, requestHeaders: headers(init.headers || request?.headers), requestBody: includeBodies ? body(init.body) : null });
            try {
              const response = await originalFetch.apply(this, arguments);
              const result = { event: 'response', ...item, status: response.status, responseHeaders: headers(response.headers), durationMs: Date.now() - started };
              if (!includeBodies) send(result);
              else {
                try {
                  void readResponseBody(response.clone()).then(responseBody => send({ ...result, responseBody }), () => send({ ...result, responseBody: null }));
                } catch { send({ ...result, responseBody: null }); }
              }
              return response;
            } catch (error) {
              send({ event: 'requestfailed', ...item, failure: String(error?.name || 'FetchError'), durationMs: Date.now() - started });
              throw error;
            }
          };
          const xhr = globalThis.XMLHttpRequest?.prototype;
          const open = xhr?.open;
          const setRequestHeader = xhr?.setRequestHeader;
          const xhrSend = xhr?.send;
          if (open) xhr.open = function (method, url) {
            this.__oxEvent = { includeBodies: control.includeBodies, resourceType: 'xhr', method, url: redactURL(url), started: Date.now(), requestHeaders: {} };
            return open.apply(this, arguments);
          };
          if (setRequestHeader) xhr.setRequestHeader = function (key, value) {
            if (this.__oxEvent) this.__oxEvent.requestHeaders[key] = sensitive.test(key) ? '[REDACTED]' : String(value).slice(0, 2048);
            return setRequestHeader.apply(this, arguments);
          };
          if (xhrSend) xhr.send = function (value) {
            const item = this.__oxEvent;
            if (!control.active || !item) return xhrSend.apply(this, arguments);
            const { includeBodies, started, requestHeaders, ...request } = item;
            send({ event: 'request', ...request, requestHeaders, requestBody: includeBodies ? body(value) : null });
            this.addEventListener('loadend', () => {
              if (this.status === 0) { send({ event: 'requestfailed', ...request, failure: 'NetworkError', durationMs: Date.now() - started }); return; }
              const responseHeaders = {};
              try {
                for (const line of this.getAllResponseHeaders().trim().split(/[\r\n]+/)) {
                  const index = line.indexOf(':');
                  if (index > 0) {
                    const key = line.slice(0, index);
                    responseHeaders[key] = sensitive.test(key) ? '[REDACTED]' : line.slice(index + 1).trim().slice(0, 2048);
                  }
                }
              } catch {}
              let responseBody = null;
              if (includeBodies) { try { responseBody = body(this.responseText); } catch {} }
              send({ event: 'response', ...request, status: this.status, responseHeaders, responseBody, durationMs: Date.now() - started });
            }, { once: true });
            return xhrSend.apply(this, arguments);
          };
          addEventListener('submit', event => {
            const form = event.target;
            let requestBody = null;
            if (control.includeBodies) { try { requestBody = body(new FormData(form)); } catch {} }
            send({ event: 'request', resourceType: 'document', method: (form.method || 'GET').toUpperCase(), url: redactURL(form.action || location.href), requestBody });
          }, true);
          try {
            new PerformanceObserver(list => {
              for (const entry of list.getEntries()) send({ event: 'requestfinished', resourceType: entry.initiatorType, url: redactURL(entry.name), durationMs: Math.round(entry.duration) });
            }).observe({ entryTypes: ['resource'] });
          } catch {}
          const OriginalWebSocket = globalThis.WebSocket;
          if (OriginalWebSocket) globalThis.WebSocket = new Proxy(OriginalWebSocket, {
            construct(target, args) {
              send({ event: 'websocket', url: redactURL(args[0]) });
              return Reflect.construct(target, args);
            }
          });
        })();
        """#
    }
}
