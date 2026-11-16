import Foundation

extension NativeServiceOperations {
    func invokeBrowserOperation(actionID: String, args: JSONValue, purpose: String?) async throws -> JSONValue? {
        let fields = args.objectValue ?? [:]
        switch actionID {
        case "newPage":
            return try await openBrowserPage(url: fields["url"]?.stringValue ?? "",
                                             networkContent: fields["networkContent"]?.stringValue.flatMap(BrowserEventLog.NetworkContent.init) ?? .omit)
        case "pages":
            return listBrowserPages()
        case "frames":
            return try await listBrowserFrames(pageID: fields["pageId"]?.stringValue ?? "")
        case "close":
            let page = try serviceManager.browserSessions.requirePage(fields["pageId"]?.stringValue ?? "", scopeID: id)
            guard page.isIdle else {
                throw OxFunctionError(code: "page_busy", message: "The selected page is busy.", recovery: "Wait for its active operation or user handoff to finish before closing it.")
            }
            serviceManager.browserActionSessions.closePage(page)
            return .object(["closed": .bool(true)])
        default:
            let session = try browserSession(arguments: fields)
            guard let selectedPage = session.page else { throw Service.EvalError.notReady }
            let operationID = UUID()
            selectedPage.activeBrowserOperations.insert(operationID)
            defer {
                selectedPage.activeBrowserOperations.remove(operationID)
                selectedPage.lastActiveAt = Date()
            }
            if ["evaluate", "pdf", "screenshot", "waitForURL", "waitForEvent"].contains(actionID) {
                return try await performBrowserOperation(actionID, fields: fields, session: session, purpose: purpose)
            }
            guard let page = session.page, let action = await serviceManager.browserService.inspectionAction() else {
                throw Service.EvalError.notReady
            }
            return try await serviceManager.actionScheduler.schedule(action, on: page, kind: .navigation, name: "ox.web.browser.\(actionID)") { _ in
                try await self.performBrowserOperation(actionID, fields: fields, session: session, purpose: purpose)
            }
        }
    }

    private func performBrowserOperation(_ actionID: String, fields: [String: JSONValue], session: ServiceBrowserActionSession, purpose: String?) async throws -> JSONValue {
        let authorizeSite = { [authorizeBrowserSite] (site: String) in try await authorizeBrowserSite(site, purpose) }
        switch actionID {
        case "goto":
            guard let raw = fields["url"]?.stringValue, let url = URL(string: raw), BrowserNavigation.allowsServiceNavigation(url) else {
                throw RuntimeError.bridge("ox.web.browser.goto requires an absolute public HTTPS URL. Simulator builds also allow loopback HTTP.")
            }
            let landed = try await session.navigate(url)
            return .object(["url": .string(landed.absoluteString)])
        case "reload":
            let landed = try await session.reload(fromOrigin: fields["fromOrigin"]?.boolValue ?? false)
            return .object(["url": landed.map { .string($0.absoluteString) } ?? .null])
        case "goBack", "goForward":
            let landed = actionID == "goBack" ? try await session.goBack() : try await session.goForward()
            return .object(["navigated": .bool(landed != nil), "url": landed.map { .string($0.absoluteString) } ?? .null])
        case "snapshot":
            return try await session.pageState(selector: fields["selector"]?.stringValue, frameID: fields["frameId"]?.stringValue, authorizeSite: authorizeSite)
        case "waitForURL":
            let landed = try await session.waitForURL(fields["url"]?.stringValue, timeoutMilliseconds: fields["timeoutMs"]?.intValue ?? 15_000)
            return .object(["url": landed.map { .string($0.absoluteString) } ?? .null])
        case "evaluate":
            return try await session.evaluate(fields["script"]?.stringValue ?? "", frameID: fields["frameId"]?.stringValue, authorizeSite: authorizeSite)
        case "pdf", "screenshot":
            let export = actionID == "pdf"
                ? try await session.exportPDF(authorizeSite: authorizeSite)
                : try await session.screenshot(authorizeSite: authorizeSite)
            let file: FileItem?
            if let filename = fields["filename"]?.stringValue {
                file = try await importFile(export.attachment, filename)
            } else {
                try attachTransient(export.attachment)
                file = nil
            }
            return .object(export.metadata.merging([
                "url": export.url.map { .string($0.absoluteString) } ?? .null,
                "contentType": .string(export.attachment.mimeType), "bytes": .int(export.attachment.data.count),
                "attached": .bool(true), "file": file.map { .string($0.fileName) } ?? .null,
            ]) { _, value in value })
        case "addInitScript":
            let landed = try await session.addInitScript(fields["script"]?.stringValue ?? "", domains: fields["domains"]?.arrayValue?.compactMap(\.stringValue) ?? [], authorizeSite: authorizeSite)
            return .object(["url": landed.map { .string($0.absoluteString) } ?? .null])
        case "events":
            return try await session.events(after: fields["after"]?.stringValue,
                                            names: fields["event"]?.stringValue.map { [$0] },
                                            limit: fields["limit"]?.intValue ?? 200, authorizeSite: authorizeSite)
        case "waitForEvent":
            return try await session.waitForEvent([fields["event"]?.stringValue ?? ""],
                                                  timeoutMilliseconds: fields["timeoutMs"]?.intValue ?? 15_000, authorizeSite: authorizeSite)
        case "readEventBody":
            return try await session.readEventBody(id: fields["id"]?.stringValue ?? "", mode: fields["mode"]?.stringValue ?? "raw", authorizeSite: authorizeSite)
        default:
            throw Service.InvokeError.unknown("ox.web.browser.\(actionID)")
        }
    }
}
