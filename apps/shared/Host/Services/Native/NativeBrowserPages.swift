import Foundation
import WebKit

extension NativeServiceOperations {
    func openBrowserPage(url raw: String, networkContent: BrowserEventLog.NetworkContent) async throws -> JSONValue {
        guard let url = URL(string: raw), BrowserNavigation.allowsServiceNavigation(url),
              let inspection = await serviceManager.browserService.inspectionAction() else {
            throw RuntimeError.bridge("ox.web.browser.newPage requires an absolute public HTTPS URL. Simulator builds also allow loopback HTTP.")
        }
        let service = serviceManager.browserService
        let action = Service.Action(service: service, definition: inspection.definition, baseURL: url,
                                    role: .blockingAction, scripts: inspection.scripts, scopeID: id)
        let page = try await service.openOwnedPage(for: action, owner: .browser(id), events: networkContent)
        do {
            let frames = try await page.discoverFrames()
            guard let main = frames.first(where: \.isMainFrame) else { throw Service.EvalError.notReady }
            _ = serviceManager.browserActionSessions.session(for: service, page: page, ownerID: id)
            Log.webView.info("Browser.open owner=\(id) page=\(page.logLabel) networkContent=\(networkContent.rawValue)")
            return .object(["pageId": .string(page.id.uuidString), "mainFrameId": .string(main.id)])
        } catch {
            serviceManager.browserSessions.close(page)
            throw error
        }
    }

    func listBrowserPages() -> JSONValue {
        let pages = serviceManager.browserSessions.sessions
            .filter { $0.scopeID != nil && $0.isOpen }
            .sorted { ($0.scopeID != id ? 1 : 0, $0.id.uuidString) < ($1.scopeID != id ? 1 : 0, $1.id.uuidString) }
        let values: [JSONValue] = pages.map { page in
            let owned = page.scopeID == id
            let url = owned ? page.page.url?.absoluteString : page.page.url.flatMap(Self.origin)
            return .object([
                "pageId": .string(page.id.uuidString),
                "url": url.map(JSONValue.string) ?? .null,
                "title": .string(owned ? page.page.title : ""),
                "isLoading": .bool(page.page.isLoading),
                "busy": .bool(!serviceManager.actionScheduler.isIdle(page)),
                "owned": .bool(owned),
            ])
        }
        Log.webView.info("Browser.pages owner=\(id) owned=\(pages.count { $0.scopeID == id }) total=\(pages.count)")
        return .object(["pages": .array(values), "limit": .int(BrowserSessionStore.maximumAgentPages)])
    }

    func listBrowserFrames(pageID: String, attached: [Service] = []) async throws -> JSONValue {
        let page = try serviceManager.browserSessions.requirePage(pageID, scopeID: id)
        guard page.secretAttempt?.holdsValues != true else {
            throw OxFunctionError(code: "page_locked", message: "The page holds a saved secret.", recovery: "Wait for the secret operation to finish.")
        }
        let frames = try await page.discoverFrames()
        return .object([
            "frames": page.frameMetadata(frames, services: serviceManager.services, attached: Set(attached.map(\.domain))),
            "framesTruncated": .bool(page.omittedFrames > 0),
        ])
    }

    private static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")"
    }

    func browserSession(arguments: [String: JSONValue]) throws -> ServiceBrowserActionSession {
        let store = serviceManager.browserSessions
        let page: BrowserSession
        if let frameID = arguments["frameId"]?.stringValue {
            page = try store.requireFramePage(frameID, scopeID: id)
        } else if let pageID = arguments["pageId"]?.stringValue {
            page = try store.requirePage(pageID, scopeID: id)
        } else {
            throw RuntimeError.bridge("An explicit pageId or frameId is required.")
        }
        try serviceManager.actionScheduler.requireNoPresentation(page)
        guard page.secretAttempt?.holdsValues != true else {
            throw OxFunctionError(code: "page_locked", message: "The page holds a saved secret.", recovery: "Wait for the secret operation to finish.")
        }
        return serviceManager.browserActionSessions.session(for: serviceManager.browserService, page: page, ownerID: id)
    }
}
