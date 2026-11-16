import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class ServiceBrowserActionSession {
    struct Export {
        let url: URL?
        let attachment: TransientAttachment
        let metadata: [String: JSONValue]
    }

    let id: UUID
    let service: Service
    private(set) var page: BrowserSession?
    private var initScript: (domains: [String], source: String)?
    private var trustedSites: Set<String> = []
    init(id: UUID, service: Service, page: BrowserSession) {
        self.id = id
        self.service = service
        self.page = page
    }

    var webPage: WebPage? {
        guard let page, service.owns(page) else { return nil }
        return page.page
    }

    func inspectionPage() async throws -> BrowserSession {
        guard let page, service.owns(page), page.isOpen else {
            throw OxFunctionError(code: "page_unavailable", message: "The selected page is unavailable.", recovery: "List owned pages. No replacement page was opened.")
        }
        guard page.secretAttempt?.holdsValues != true else {
            throw OxFunctionError(code: "page_locked", message: "This page holds a saved secret during a login.", recovery: "Wait for the login to finish before inspecting the page.")
        }
        return page
    }

    func navigate(_ url: URL, timeout: TimeInterval = 15) async throws -> URL {
        let page = try await inspectionPage()
        guard let landed = await service.navigate(url, in: page, timeout: timeout) else {
            throw Service.EvalError.navigationFailed(page.navigationFailure ?? "Browser did not complete the navigation")
        }
        return landed
    }

    func reload(fromOrigin: Bool = false, timeout: TimeInterval = 15) async throws -> URL? {
        let page = try await inspectionPage()
        return await service.reload(page, fromOrigin: fromOrigin, timeout: timeout)
    }

    func goBack(timeout: TimeInterval = 15) async throws -> URL? {
        let page = try await inspectionPage()
        return await service.goBack(page, timeout: timeout)
    }

    func goForward(timeout: TimeInterval = 15) async throws -> URL? {
        let page = try await inspectionPage()
        return await service.goForward(page, timeout: timeout)
    }

    func waitForURL(_ pattern: String?, timeoutMilliseconds: Int) async throws -> URL? {
        let page = try await inspectionPage()
        let webPage = page.page
        let matches = { (url: URL?) in pattern.map { Self.url(url, matches: $0) } ?? true }
        if pattern != nil, !webPage.isLoading, matches(webPage.url) { return webPage.url }
        return try await withThrowingTaskGroup(of: URL?.self) { group in
            group.addTask { @MainActor in
                for try await event in webPage.navigations where event == .finished && matches(webPage.url) {
                    return webPage.url
                }
                throw RuntimeError.bridge("ox.web.browser.waitForURL ended before a matching navigation finished.")
            }
            group.addTask { @MainActor in
                try await Task.sleep(for: .milliseconds(timeoutMilliseconds))
                throw RuntimeError.bridge("ox.web.browser.waitForURL timed out.")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw RuntimeError.bridge("ox.web.browser.waitForURL produced no result.")
            }
            Log.webView.info("Browser.waitForURL owner=\(id) host=\(result?.host?.lowercased() ?? "?") pattern=\(pattern != nil)")
            return result
        }
    }

    nonisolated static func url(_ url: URL?, matches pattern: String) -> Bool {
        guard let value = url?.absoluteString else { return false }
        let parts = pattern.components(separatedBy: "*")
        guard parts.count > 1 else { return value == pattern }
        guard value.hasPrefix(parts[0]), value.hasSuffix(parts[parts.count - 1]) else { return false }
        var remainder = value.dropFirst(parts[0].count)
        for part in parts.dropFirst().dropLast() where !part.isEmpty {
            guard let range = remainder.range(of: part) else { return false }
            remainder = remainder[range.upperBound...]
        }
        return remainder.count >= parts[parts.count - 1].count
    }

    func pageState(selector: String?, frameID: String? = nil, prepared: (Service, BrowserSession)? = nil,
                   attached: [Service] = [], authorizeSite: (String) async throws -> Void) async throws -> JSONValue {
        let owner = prepared?.0 ?? service
        try await owner.awaitAuthenticationAvailability(name: "ox.web.browser.snapshot")
        guard let page = prepared?.1 ?? page, owner.owns(page), page.secretAttempt?.holdsValues != true else {
            throw Service.EvalError.notReady
        }
        let approval = try await authorize(page, authorizeSite)
        let generation = page.navigationGeneration
        try await owner.installFrameServices(attached, on: page)
        Log.webView.info("Browser.state phase=installed page=\(page.logLabel) targeted=\(frameID != nil)")
        let target: BrowserSession.FrameTarget?
        if let frameID { target = try await page.requireFrame(frameID) } else { target = nil }
        Log.webView.info("Browser.state phase=selected page=\(page.logLabel) origin=\(target?.origin ?? "main")")
        if let target, let host = URL(string: target.origin)?.host {
            try await trust(ServiceWebsiteDataCoordinator.site(for: host), authorizeSite)
        }
        Log.webView.info("Browser.state phase=authorized page=\(page.logLabel)")
        try Self.requireUnchanged(page, since: approval)
        try await owner.manager.requireInvocationAccess(for: owner)
        let script = BrowserPageState.script(selector: selector)
        let raw = try await owner.evalOnce(page, target?.guarded(script) ?? script, timeout: 3, frame: target?.info)
        guard owner.owns(page), page.navigationGeneration == generation else { throw Service.EvalError.contextInvalidated }
        var result = stateResult(raw.map(JSONValue.from) ?? .null, page: page).objectValue ?? [:]
        result["frameId"] = frameID.map(JSONValue.string) ?? .null
        result["frames"] = page.frameMetadata(Array(page.frameTargets.values), services: owner.manager.services, attached: Set(attached.map(\.domain)))
        result["framesTruncated"] = .bool(page.omittedFrames > 0)
        Log.webView.info("Browser.state owner=\(id) page=\(page.logLabel) generation=\(generation) frames=\(page.frameTargets.count)")
        return .object(result)
    }

    func evaluate(_ script: String, frameID: String? = nil, authorizeSite: (String) async throws -> Void) async throws -> JSONValue {
        let name = "ox.web.browser.evaluate"
        try await service.awaitAuthenticationAvailability(name: name)
        guard let action = await service.resolvedAction("evaluate", role: .dangerousBrowserControl) else {
            throw Service.EvalError.notActive
        }
        let page = try await inspectionPage()
        let approval = try await authorize(page, authorizeSite)
        let target: BrowserSession.FrameTarget?
        if let frameID { target = try await page.requireFrame(frameID) } else { target = nil }
        if let target, let host = URL(string: target.origin)?.host {
            try await trust(ServiceWebsiteDataCoordinator.site(for: host), authorizeSite)
        }
        return try await service.executeBrowserJavaScript(script, action: action, in: page, frame: target) { page in
            try Self.requireUnchanged(page, since: approval)
        }
    }

    private func stateResult(_ result: JSONValue, page: BrowserSession) -> JSONValue {
        let webPage = page.page
        let fullscreenState: String = switch webPage.fullscreenState {
        case .enteringFullscreen: "enteringFullscreen"
        case .exitingFullscreen: "exitingFullscreen"
        case .inFullscreen: "inFullscreen"
        case .notInFullscreen: "notInFullscreen"
        @unknown default: "unknown"
        }
        return .object([
            "pageID": .string(page.id.uuidString),
            "navigationGeneration": .int(page.navigationGeneration),
            "url": webPage.url.map { .string($0.absoluteString) } ?? .null,
            "title": .string(webPage.title),
            "estimatedProgress": .double(webPage.estimatedProgress),
            "isLoading": .bool(webPage.isLoading),
            "hasOnlySecureContent": .bool(webPage.hasOnlySecureContent),
            "isBlockedByScreenTime": .bool(webPage.isBlockedByScreenTime),
            "fullscreenState": .string(fullscreenState),
            "document": result,
        ])
    }

    func exportPDF(authorizeSite: (String) async throws -> Void) async throws -> Export {
        try await export("pdf", authorizeSite: authorizeSite) { page in
            let prepared = try PDFPreparer.prepareFile(try await page.page.exported(as: .pdf()))
            let attachment = TransientAttachment(kind: .pdf, mimeType: prepared.mimeType, displayName: "Browser Page.pdf", data: prepared.data)
            return (attachment, ["pages": .int(prepared.pageCount)])
        }
    }

    func screenshot(authorizeSite: (String) async throws -> Void) async throws -> Export {
        try await export("screenshot", authorizeSite: authorizeSite) { page in
            let prepared = try ImagePreparer.prepare(try await page.page.exported(as: .image(region: .contents)))
            let inspection = try ImagePreparer.inspect(prepared.data)
            let attachment = TransientAttachment(kind: .image, mimeType: prepared.mimeType, displayName: "Browser Page.\(prepared.fileExtension)", data: prepared.data)
            return (attachment, ["width": .int(inspection.width), "height": .int(inspection.height)])
        }
    }

    private func export(
        _ actionID: String,
        authorizeSite: (String) async throws -> Void,
        render: @escaping @MainActor (BrowserSession) async throws -> (TransientAttachment, [String: JSONValue])
    ) async throws -> Export {
        let name = "ox.web.browser.\(actionID)"
        try await service.awaitAuthenticationAvailability(name: name)
        guard let action = await service.resolvedAction(actionID, role: .dangerousBrowserControl) else {
            throw Service.EvalError.notActive
        }
        let page = try await inspectionPage()
        let approval = try await authorize(page, authorizeSite)
        return try await service.manager.actionScheduler.schedule(action, on: page, name: name) { page in
            try Self.requireUnchanged(page, since: approval)
            let (attachment, metadata) = try await render(page)
            try Self.requireUnchanged(page, since: approval)
            Log.webView.info("Browser.\(actionID) host=\(page.page.url?.host?.lowercased() ?? "?") bytes=\(attachment.data.count)")
            return Export(url: page.page.url, attachment: attachment, metadata: metadata)
        }
    }

    func addInitScript(_ source: String, domains: [String], authorizeSite: (String) async throws -> Void) async throws -> URL? {
        let normalized = domains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty,
              normalized.count <= 50,
              normalized.allSatisfy({
                  $0.range(of: #"^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$"#, options: .regularExpression) != nil
              }),
              source.utf8.count <= 100_000 else {
            throw Service.EvalError.js("invalid or excessive document-start script")
        }
        let sites = normalized.map(ServiceWebsiteDataCoordinator.registrableSite(for:))
        guard sites.allSatisfy({ $0 != nil }) else {
            throw Service.EvalError.js("document-start script domains must be registrable domains, their subdomains, or IP addresses")
        }
        for site in Set(sites.compactMap { $0 }).sorted() {
            try await trust(site, authorizeSite)
        }
        let page = try await inspectionPage()
        let previous = initScript
        initScript = (domains: Array(Set(normalized)).sorted(), source: source)
        configureAuthoringScripts(on: page)
        Log.webView.info("Browser.addInitScript owner=\(id) domains=\(normalized.count) bytes=\(source.utf8.count) replaced=\(previous != nil)")
        guard let landed = await service.reload(page) else {
            let failure = page.navigationFailure ?? "Browser did not reload after adding an init script"
            initScript = previous
            discardPage(page)
            throw Service.EvalError.navigationFailed(failure)
        }
        return landed
    }

    func events(after: String?, names: Set<String>?, limit: Int, authorizeSite: (String) async throws -> Void) async throws -> JSONValue {
        let page = try await inspectionPage()
        _ = try await authorize(page, authorizeSite)
        return try page.events.read(after: after, names: names, limit: limit)
    }

    func waitForEvent(_ names: Set<String>, timeoutMilliseconds: Int, authorizeSite: (String) async throws -> Void) async throws -> JSONValue {
        let page = try await inspectionPage()
        _ = try await authorize(page, authorizeSite)
        return try await page.events.next(names, timeoutMilliseconds: timeoutMilliseconds)
    }

    func readEventBody(id: String, mode: String, authorizeSite: (String) async throws -> Void) async throws -> JSONValue {
        let page = try await inspectionPage()
        guard var fields = page.events.record(id: id)?.objectValue,
              ["request", "response"].contains(fields["event"]?.stringValue ?? "") else {
            throw OxFunctionError(code: "event_unavailable", message: "The event is unavailable or has no body.", recovery: "Read events again and use a retained request or response event id.")
        }
        if let site = fields["site"]?.stringValue { try await trust(site, authorizeSite) }
        let bodies = ["requestBody", "responseBody"].filter { fields[$0] != nil && fields[$0] != .null }
        Log.webView.info("Browser.readEventBody owner=\(self.id) event=\(id) mode=\(mode) bodies=\(bodies.count)")
        guard mode == "shape" else {
            return .object(["id": .string(id), "requestBody": fields["requestBody"] ?? .null, "responseBody": fields["responseBody"] ?? .null])
        }
        var result: [String: JSONValue] = ["id": .string(id)]
        var coverage: [String: JSONValue] = [:]
        for side in ["request", "response"] {
            let text = fields.removeValue(forKey: "\(side)Body")?.stringValue
            var budget = 128
            var truncated = false
            let parsed = text.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
            result["\(side)Shape"] = parsed.map { Self.bodyShape($0, depth: 0, budget: &budget, truncated: &truncated) } ?? .null
            coverage[side] = .object([
                "status": .string(text == nil ? "unavailable" : parsed == nil ? "invalid_json" : "json"),
                "shapeTruncated": .bool(truncated),
                "bodyCompleteness": .string("unknown"),
            ])
        }
        result["bodyCoverage"] = .object(coverage)
        return .object(result)
    }

    private static func bodyShape(_ value: JSONValue, depth: Int, budget: inout Int, truncated: inout Bool) -> JSONValue {
        guard budget > 0, depth < 5 else {
            truncated = true
            return .object(["type": .string("uninspected")])
        }
        budget -= 1
        switch value {
        case .object(let fields):
            var properties: [String: JSONValue] = [:]
            for key in fields.keys.sorted() {
                guard budget > 0 else { truncated = true; break }
                guard key.count <= 256 else { truncated = true; continue }
                properties[key] = bodyShape(fields[key]!, depth: depth + 1, budget: &budget, truncated: &truncated)
            }
            return .object(["type": .string("object"), "properties": .object(properties)])
        case .array(let values):
            var items: [JSONValue] = []
            if values.count > 5 { truncated = true }
            for value in values.prefix(5) {
                guard budget > 0 else { truncated = true; break }
                let shape = bodyShape(value, depth: depth + 1, budget: &budget, truncated: &truncated)
                if !items.contains(shape) { items.append(shape) }
            }
            return .object(["type": .string("array"), "items": .array(items)])
        case .string: return .object(["type": .string("string")])
        case .int, .double: return .object(["type": .string("number")])
        case .bool: return .object(["type": .string("boolean")])
        case .null: return .object(["type": .string("null")])
        }
    }

    private static func site(of page: BrowserSession) -> String? {
        page.page.url?.host(percentEncoded: false).flatMap { $0.isEmpty ? nil : ServiceWebsiteDataCoordinator.site(for: $0) }
    }

    private func authorize(
        _ page: BrowserSession,
        _ authorizeSite: (String) async throws -> Void
    ) async throws -> (generation: Int, site: String?) {
        let approval = (generation: page.navigationGeneration, site: Self.site(of: page))
        if let site = approval.site { try await trust(site, authorizeSite) }
        return approval
    }

    private func trust(_ site: String, _ authorizeSite: (String) async throws -> Void) async throws {
        let blocked = service.manager.actionPolicy(for: Actions.browserSite(site), default: .ask) == .block
        guard blocked || !trustedSites.contains(site) else { return }
        try await authorizeSite(site)
        trustedSites.insert(site)
        Log.webView.info("Service.browserSession event=trust owner=\(id) site=\(site)")
    }

    private static func requireUnchanged(_ page: BrowserSession, since approval: (generation: Int, site: String?)) throws {
        guard page.navigationGeneration == approval.generation, site(of: page) == approval.site else {
            throw Service.EvalError.contextInvalidated
        }
    }

    func prepareForUserInteraction() async throws {
        guard let page else { return }
        await page.setEventRecording(paused: true)
        guard initScript != nil else { return }
        initScript = nil
        configureAuthoringScripts(on: page)
        guard await service.reload(page) != nil else {
            let failure = page.navigationFailure ?? "Browser did not reload before user interaction"
            discardPage(page)
            throw Service.EvalError.navigationFailed(failure)
        }
    }

    func finishUserInteraction() async {
        guard let page, page.isOpen else { return }
        await page.setEventRecording(paused: false)
    }

    func close() {
        if let page {
            service.closeOwnedPage(page)
            self.page = nil
        }
        initScript = nil
        Log.webView.info("Service.browserSession event=close owner=\(id) domain=\(service.domain)")
    }

    private func configureAuthoringScripts(on page: BrowserSession) {
        var scripts: [WKUserScript] = []
        if let script = initScript {
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
        Log.webView.info("Service.browserSession event=scripts owner=\(id) init=\(initScript != nil)")
    }

    private func discardPage(_ page: BrowserSession) {
        service.closeOwnedPage(page)
        if self.page === page {
            self.page = nil
        }
    }

}

@MainActor
@Observable
final class ServiceBrowserActionSessionCoordinator {
    private var sessions: [UUID: ServiceBrowserActionSession] = [:]

    func session(for service: Service, page: BrowserSession, ownerID: UUID) -> ServiceBrowserActionSession {
        if let session = sessions[page.id] { return session }
        let session = ServiceBrowserActionSession(id: ownerID, service: service, page: page)
        sessions[page.id] = session
        return session
    }

    func closePage(_ page: BrowserSession) {
        sessions.removeValue(forKey: page.id)?.close()
        if page.manager.browserSessions.contains(page) { page.manager.browserSessions.close(page) }
    }

    func existingSession(for ownerID: UUID, service: Service? = nil) -> ServiceBrowserActionSession? {
        let matches = sessions.values.filter { $0.id == ownerID && $0.webPage != nil && (service == nil || $0.service === service) }
        return matches.count == 1 ? matches.first : nil
    }

    func closeSession(for ownerID: UUID) {
        for (id, session) in sessions.filter({ $0.value.id == ownerID }) {
            sessions.removeValue(forKey: id)
            session.close()
        }
    }
}
