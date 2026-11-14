import Foundation
import WebKit

extension NativeServiceOperations {
    func openBrowserPage(url raw: String) async throws -> JSONValue {
        guard let url = URL(string: raw), BrowserNavigation.allowsServiceNavigation(url),
              let inspection = await serviceManager.browserService.inspectionAction() else {
            throw RuntimeError.bridge("ox.web.browser.open requires an absolute public HTTPS URL. Simulator builds also allow loopback HTTP.")
        }
        let service = serviceManager.browserService
        let action = Service.Action(service: service, definition: inspection.definition, baseURL: url,
                                    role: .blockingAction, scripts: inspection.scripts, scopeID: id)
        let page = try await service.openOwnedPage(for: action, owner: .browser(id))
        do {
            let frames = try await page.discoverFrames()
            guard let main = frames.first(where: \.isMainFrame) else { throw Service.EvalError.notReady }
            _ = serviceManager.browserActionSessions.session(for: service, page: page, ownerID: id)
            Log.webView.info("Browser.open owner=\(id) page=\(page.logLabel)")
            return .object(["pageId": .string(page.id.uuidString), "mainFrameId": .string(main.id)])
        } catch {
            serviceManager.browserSessions.close(page)
            throw error
        }
    }

    func listBrowserPages(includeFrames: Bool, attached: [Service] = []) async throws -> JSONValue {
        var values: [JSONValue] = []
        for page in serviceManager.browserSessions.sessions.filter({ $0.scopeID == id && $0.isOpen }).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            var fields: [String: JSONValue] = [
                "pageId": .string(page.id.uuidString),
                "url": page.page.url.map { .string($0.absoluteString) } ?? .null,
                "title": .string(page.page.title),
                "isLoading": .bool(page.page.isLoading),
                "busy": .bool(!serviceManager.actionScheduler.isIdle(page)),
            ]
            if includeFrames {
                guard page.secretAttempt?.holdsValues != true else {
                    throw OxFunctionError(code: "page_locked", message: "A page holds a saved secret.", recovery: "List pages without frames or wait for the secret operation to finish.")
                }
                let frames = try await page.discoverFrames()
                fields["frames"] = page.frameMetadata(frames, services: serviceManager.services, attached: Set(attached.map(\.domain)))
                fields["framesTruncated"] = .bool(page.omittedFrames > 0)
            }
            values.append(.object(fields))
        }
        return .object(["pages": .array(values), "limit": .int(BrowserSessionStore.maximumAgentPages)])
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
