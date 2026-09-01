import Foundation
import Observation
import WebKit

@MainActor
final class ServiceBrowserActionSession {
    struct ExportedPDF {
        let url: URL?
        let attachment: TransientAttachment
        let pages: Int
    }

    private final class CaptureSink: NSObject, WKScriptMessageHandler {
        weak var session: ServiceBrowserActionSession?

        init(session: ServiceBrowserActionSession) {
            self.session = session
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            let body = message.body
            Task { @MainActor [weak self] in
                self?.session?.receiveCapture(body)
            }
        }
    }

    private struct Opening {
        let id: UUID
        let baseURL: URL
        let task: Task<Service.ServiceWebPage, Error>
    }

    let id: UUID
    let service: Service
    private var loadedBaseURL: URL?
    private var opening: Opening?
    private(set) var page: Service.ServiceWebPage?
    private var captureSink: CaptureSink?
    private var capturedEvents: [JSONValue] = []
    private var injectedScripts: [(domains: [String], source: String)] = []
    private var captureActive = false

    init(id: UUID, service: Service) {
        self.id = id
        self.service = service
    }

    var webPage: WebPage? {
        guard let page, service.owns(page), page.isReady else { return nil }
        return page.page
    }

    func inspectionPage() async throws -> Service.ServiceWebPage {
        guard let action = await service.inspectionAction() else { throw Service.EvalError.notActive }
        return try await page(for: action)
    }

    func navigate(_ url: URL, timeout: TimeInterval = 15) async throws -> URL {
        guard let action = await service.inspectionAction() else { throw Service.EvalError.notActive }
        let page = try await page(for: action)
        guard let landed = await service.navigate(url, in: page, timeout: timeout) else {
            throw Service.EvalError.navigationFailed(page.navigationFailure ?? "Browser did not complete the navigation")
        }
        return landed
    }

    func reload(fromOrigin: Bool = false, timeout: TimeInterval = 15) async -> URL? {
        guard let action = await service.inspectionAction(),
              let page = try? await page(for: action) else { return nil }
        return await service.reload(page, fromOrigin: fromOrigin, timeout: timeout)
    }

    func stopLoading() async throws -> URL? {
        let page = try await inspectionPage()
        page.page.stopLoading()
        Log.webView.info("Browser.stopLoading host=\(page.page.url?.host?.lowercased() ?? "?")")
        return page.page.url
    }

    func goBack(timeout: TimeInterval = 15) async -> URL? {
        guard let action = await service.inspectionAction(),
              let page = try? await page(for: action) else { return nil }
        return await service.goBack(page, timeout: timeout)
    }

    func goForward(timeout: TimeInterval = 15) async -> URL? {
        guard let action = await service.inspectionAction(),
              let page = try? await page(for: action) else { return nil }
        return await service.goForward(page, timeout: timeout)
    }

    func navigationHistory() async throws -> JSONValue {
        let page = try await inspectionPage()
        let webPage = page.page
        let history = webPage.backForwardList
        return .object([
            "back": .array(history.backList.map(Self.historyItem)),
            "current": history.currentItem.map(Self.historyItem) ?? .null,
            "forward": .array(history.forwardList.map(Self.historyItem)),
        ])
    }

    func pageInfo() async throws -> JSONValue {
        let page = try await inspectionPage()
        let webPage = page.page
        let fullscreenState: String = switch webPage.fullscreenState {
        case .enteringFullscreen: "enteringFullscreen"
        case .exitingFullscreen: "exitingFullscreen"
        case .inFullscreen: "inFullscreen"
        case .notInFullscreen: "notInFullscreen"
        @unknown default: "unknown"
        }
        return .object([
            "url": webPage.url.map { .string($0.absoluteString) } ?? .null,
            "title": .string(webPage.title),
            "estimatedProgress": .double(webPage.estimatedProgress),
            "isLoading": .bool(webPage.isLoading),
            "hasOnlySecureContent": .bool(webPage.hasOnlySecureContent),
            "isBlockedByScreenTime": .bool(webPage.isBlockedByScreenTime),
            "fullscreenState": .string(fullscreenState),
        ])
    }

    func waitForNavigation(timeoutMilliseconds: Int) async throws -> URL? {
        let page = try await inspectionPage()
        let webPage = page.page
        return try await withThrowingTaskGroup(of: URL?.self) { group in
            group.addTask { @MainActor in
                for try await event in webPage.navigations {
                    if event == .finished { return webPage.url }
                }
                throw RuntimeError.bridge("ios:browser:waitForNavigation ended before navigation finished.")
            }
            group.addTask { @MainActor in
                try await Task.sleep(for: .milliseconds(timeoutMilliseconds))
                throw RuntimeError.bridge("ios:browser:waitForNavigation timed out.")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw RuntimeError.bridge("ios:browser:waitForNavigation produced no result.")
            }
            return result
        }
    }

    func executeScript(_ script: String) async throws -> JSONValue {
        let name = "ios:browser:executeScript"
        try await service.awaitAuthenticationAvailability(name: name)
        guard let action = await service.resolvedAction("executeScript", role: .dangerousBrowserControl) else {
            throw Service.EvalError.notActive
        }
        let page = try await page(for: action)
        return try await service.executeBrowserJavaScript(script, action: action, in: page)
    }

    func exportPDF() async throws -> ExportedPDF {
        let name = "ios:browser:exportPdf"
        try await service.awaitAuthenticationAvailability(name: name)
        guard let action = await service.resolvedAction("exportPdf", role: .dangerousBrowserControl) else {
            throw Service.EvalError.notActive
        }
        let page = try await page(for: action)
        return try await service.manager.actionScheduler.schedule(action, on: page, name: name) { page in
            let generation = page.navigationGeneration
            let data = try await page.page.exported(as: .pdf())
            guard generation == page.navigationGeneration else { throw Service.EvalError.contextInvalidated }
            let prepared = try PDFPreparer.prepareArtifact(data)
            let attachment = TransientAttachment(
                kind: .pdf,
                mimeType: prepared.mimeType,
                displayName: "Browser Page.pdf",
                data: prepared.data
            )
            let host = page.page.url?.host?.lowercased() ?? "?"
            Log.webView.info("Browser.exportPdf host=\(host) pages=\(prepared.pageCount) bytes=\(prepared.data.count)")
            return ExportedPDF(
                url: page.page.url,
                attachment: attachment,
                pages: prepared.pageCount
            )
        }
    }

    func injectScript(_ source: String, domains: [String]) async throws -> URL? {
        let normalized = domains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty,
              normalized.count <= 50,
              normalized.allSatisfy({
                  $0.range(of: #"^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$"#, options: .regularExpression) != nil
              }),
              source.utf8.count <= 100_000,
              injectedScripts.count < 20 else {
            throw Service.EvalError.js("invalid or excessive document-start script")
        }
        injectedScripts.append((domains: Array(Set(normalized)).sorted(), source: source))
        let page = try await inspectionPage()
        configureAuthoringScripts(on: page)
        return await service.reload(page)
    }

    func clearScripts() async throws -> URL? {
        guard !injectedScripts.isEmpty else {
            Log.webView.info("Browser.authoring clearScripts skipped=empty session=\(id.uuidString.prefix(8))")
            return page?.page.url
        }
        injectedScripts = []
        let page = try await inspectionPage()
        configureAuthoringScripts(on: page)
        return await service.reload(page)
    }

    func startCapture() async throws -> URL? {
        capturedEvents = []
        captureActive = true
        let page = try await inspectionPage()
        configureAuthoringScripts(on: page)
        return await service.reload(page)
    }

    func stopCapture() {
        captureActive = false
        if let page { configureAuthoringScripts(on: page) }
    }

    func markCapture(_ label: String) {
        guard captureActive else { return }
        appendCapturedEvent(.object([
            "id": .string(UUID().uuidString),
            "kind": .string("mark"),
            "label": .string(label),
            "timestamp": .double(Date().timeIntervalSince1970 * 1_000),
        ]))
    }

    func listCapturedEvents() -> [JSONValue] {
        capturedEvents.map { event in
            guard var fields = event.objectValue else { return event }
            fields.removeValue(forKey: "requestBody")
            fields.removeValue(forKey: "responseBody")
            return .object(fields)
        }
    }

    func readCapturedEvent(id: String) -> JSONValue? {
        capturedEvents.first { $0.objectValue?["id"]?.stringValue == id }
    }

    func close() {
        opening?.task.cancel()
        opening = nil
        loadedBaseURL = nil
        if let page {
            page.userContentController.removeScriptMessageHandler(forName: "oxBrowserCapture")
            service.closeOwnedPage(page)
            self.page = nil
        }
        captureSink = nil
        capturedEvents = []
        injectedScripts = []
        captureActive = false
        Log.webView.info("Service.browserSession event=close owner=\(id) domain=\(service.domain)")
    }

    private func configureAuthoringScripts(on page: Service.ServiceWebPage) {
        let controller = page.userContentController
        controller.removeScriptMessageHandler(forName: "oxBrowserCapture")
        captureSink = nil
        var scripts: [WKUserScript] = []
        if captureActive {
            let sink = CaptureSink(session: self)
            captureSink = sink
            controller.add(sink, name: "oxBrowserCapture")
            scripts.append(WKUserScript(
                source: Self.captureScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
        }
        for script in injectedScripts {
            let domains = (try? JSONSerialization.data(withJSONObject: script.domains))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let source = """
            (() => {
              const domains = \(domains);
              const host = location.hostname.toLowerCase();
              if (!domains.some(domain => host === domain || host.endsWith('.' + domain))) return;
              \(script.source)
            })();
            """
            scripts.append(WKUserScript(
                source: source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
        }
        page.additionalUserScripts = scripts
        page.scriptMode = nil
        service.configureScripts(for: page.page.url, in: page)
        Log.webView.info("Service.browserSession event=scripts owner=\(id) capture=\(captureActive) injected=\(injectedScripts.count)")
    }

    private func receiveCapture(_ body: Any) {
        guard captureActive else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: body), data.count <= 100_000 else {
            Log.webView.warning("Service.browserSession event=capture-dropped owner=\(id)")
            return
        }
        var fields = JSONValue.from(body).objectValue ?? [:]
        fields["id"] = .string(UUID().uuidString)
        appendCapturedEvent(.object(fields))
    }

    private func appendCapturedEvent(_ event: JSONValue) {
        capturedEvents.append(event)
        if capturedEvents.count > 500 {
            capturedEvents.removeFirst(capturedEvents.count - 500)
        }
    }

    private static func historyItem(_ item: WebPage.BackForwardList.Item) -> JSONValue {
        .object([
            "title": item.title.map(JSONValue.string) ?? .null,
            "url": .string(item.url.absoluteString),
            "initialUrl": .string(item.initialURL.absoluteString),
        ])
    }

    private static let captureScript = #"""
    (() => {
      if (globalThis.__oxCaptureInstalled) return;
      globalThis.__oxCaptureInstalled = true;
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
          for (const [key, entry] of value) fields[key] = sensitive.test(key) ? '[REDACTED]' : String(entry).slice(0, 2048);
          return JSON.stringify(fields);
        }
        if (typeof value !== 'string') return `[${value.constructor?.name || typeof value}]`;
        const text = value.slice(0, 8192);
        try {
          const parsed = JSON.parse(text);
          const clean = item => Array.isArray(item) ? item.map(clean) : item && typeof item === 'object'
            ? Object.fromEntries(Object.entries(item).map(([key, entry]) => [key, sensitive.test(key) ? '[REDACTED]' : clean(entry)])) : item;
          return JSON.stringify(clean(parsed));
        } catch { return sensitive.test(text) ? '[REDACTED]' : text; }
      };
      const send = value => { try { webkit.messageHandlers.oxBrowserCapture.postMessage({ timestamp: Date.now(), frameURL: redactURL(location.href), ...value }); } catch {} };
      const originalFetch = globalThis.fetch;
      if (originalFetch) globalThis.fetch = async function(input, init = {}) {
        const request = input instanceof Request ? input : null;
        const started = Date.now();
        const item = { kind: 'fetch', method: init.method || request?.method || 'GET', url: redactURL(request?.url || input), requestHeaders: headers(init.headers || request?.headers), requestBody: body(init.body) };
        try {
          const response = await originalFetch.apply(this, arguments);
          let responseBody = null;
          try { responseBody = body(await response.clone().text()); } catch {}
          send({ ...item, status: response.status, responseHeaders: headers(response.headers), responseBody, durationMs: Date.now() - started });
          return response;
        } catch (error) { send({ ...item, error: String(error), durationMs: Date.now() - started }); throw error; }
      };
      const open = XMLHttpRequest.prototype.open;
      const setRequestHeader = XMLHttpRequest.prototype.setRequestHeader;
      const xhrSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(method, url) { this.__oxCapture = { kind: 'xhr', method, url: redactURL(url), started: Date.now() }; return open.apply(this, arguments); };
      XMLHttpRequest.prototype.setRequestHeader = function(key, value) {
        const item = this.__oxCapture || (this.__oxCapture = { kind: 'xhr', method: 'GET', url: location.href, started: Date.now() });
        (item.requestHeaders || (item.requestHeaders = {}))[key] = sensitive.test(key) ? '[REDACTED]' : String(value).slice(0, 2048);
        return setRequestHeader.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function(value) {
        const item = this.__oxCapture || { kind: 'xhr', method: 'GET', url: location.href, started: Date.now() };
        item.requestBody = body(value);
        this.addEventListener('loadend', () => {
          let responseBody = null;
          const responseHeaders = {};
          try { responseBody = body(this.responseText); } catch {}
          try {
            for (const line of this.getAllResponseHeaders().trim().split(/[\r\n]+/)) {
              const index = line.indexOf(':');
              if (index > 0) {
                const key = line.slice(0, index);
                responseHeaders[key] = sensitive.test(key) ? '[REDACTED]' : line.slice(index + 1).trim().slice(0, 2048);
              }
            }
          } catch {}
          send({ ...item, status: this.status, responseHeaders, responseBody, durationMs: Date.now() - item.started });
        }, { once: true });
        return xhrSend.apply(this, arguments);
      };
      addEventListener('submit', event => {
        const form = event.target;
        const fields = {};
        try { for (const [key, value] of new FormData(form)) fields[key] = sensitive.test(key) ? '[REDACTED]' : String(value).slice(0, 2048); } catch {}
        send({ kind: 'form', method: (form.method || 'GET').toUpperCase(), url: redactURL(form.action || location.href), requestBody: JSON.stringify(fields) });
      }, true);
      try {
        new PerformanceObserver(list => { for (const item of list.getEntries()) send({ kind: 'resource', url: redactURL(item.name), initiatorType: item.initiatorType, durationMs: Math.round(item.duration) }); }).observe({ type: 'resource', buffered: true });
      } catch {}
      const OriginalWebSocket = globalThis.WebSocket;
      if (OriginalWebSocket) globalThis.WebSocket = new Proxy(OriginalWebSocket, { construct(target, args) { send({ kind: 'websocket', url: redactURL(args[0]), event: 'open' }); return Reflect.construct(target, args); } });
    })();
    """#

    private func page(for action: Service.Action) async throws -> Service.ServiceWebPage {
        guard service.domain == "ios:browser" else { throw Service.EvalError.notActive }
        if let page,
           loadedBaseURL == action.baseURL,
           service.owns(page),
           page.isReady {
            return page
        }
        if let opening, opening.baseURL == action.baseURL {
            let page = try await opening.task.value
            guard service.owns(page), page.isReady else { throw Service.EvalError.contextInvalidated }
            return page
        }

        opening?.task.cancel()
        opening = nil
        if let page {
            service.closeOwnedPage(page)
            self.page = nil
        }
        loadedBaseURL = nil

        let openingID = UUID()
        let task = Task { @MainActor in
            let page = try await service.openOwnedPage(for: action, owner: .browser(id))
            do {
                try Task.checkCancellation()
                return page
            } catch {
                service.closeOwnedPage(page)
                throw error
            }
        }
        opening = Opening(id: openingID, baseURL: action.baseURL, task: task)
        do {
            let page = try await task.value
            guard opening?.id == openingID else {
                service.closeOwnedPage(page)
                throw Service.EvalError.contextInvalidated
            }
            opening = nil
            loadedBaseURL = action.baseURL
            self.page = page
            Log.webView.info("Service.browserSession event=open owner=\(id) domain=\(service.domain) session=\(page.logLabel)")
            return page
        } catch {
            if opening?.id == openingID { opening = nil }
            throw error
        }
    }
}

@MainActor
@Observable
final class ServiceBrowserActionSessionCoordinator {
    private var sessions: [UUID: ServiceBrowserActionSession] = [:]

    func session(for service: Service, ownerID: UUID) -> ServiceBrowserActionSession {
        if let session = sessions[ownerID], session.service === service { return session }
        sessions.removeValue(forKey: ownerID)?.close()
        let session = ServiceBrowserActionSession(id: ownerID, service: service)
        sessions[ownerID] = session
        Log.webView.info("Service.browserSession event=create owner=\(ownerID) domain=\(service.domain) resident=\(sessions.count)")
        return session
    }

    func existingSession(for ownerID: UUID, service: Service? = nil) -> ServiceBrowserActionSession? {
        guard let session = sessions[ownerID] else { return nil }
        guard service == nil || session.service === service else { return nil }
        return session
    }

    func closeSession(for ownerID: UUID) {
        guard let session = sessions.removeValue(forKey: ownerID) else { return }
        session.close()
        Log.webView.info("Service.browserSession event=remove owner=\(ownerID) resident=\(sessions.count)")
    }
}
