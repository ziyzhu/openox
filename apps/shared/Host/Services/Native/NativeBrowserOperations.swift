import Foundation

extension NativeServiceOperations {
    func invokeBrowserOperation(actionID: String, args: JSONValue, purpose: String?) async throws -> JSONValue? {
        let fields = args.objectValue ?? [:]
        switch actionID {
        case "newPage":
            return try await openBrowserPage(url: fields["url"]?.stringValue ?? "")
        case "pages":
            return listBrowserPages()
        case "frames":
            return try await listBrowserFrames(pageID: fields["pageId"]?.stringValue ?? "")
        case "close":
            let page = try serviceManager.browserSessions.requirePage(fields["pageId"]?.stringValue ?? "", scopeID: id)
            guard serviceManager.actionScheduler.isIdle(page) else {
                throw OxFunctionError(code: "page_busy", message: "The selected page is busy.", recovery: "Wait for its active operation or user handoff to finish before closing it.")
            }
            serviceManager.browserActionSessions.closePage(page)
            return .object(["closed": .bool(true)])
        default:
            let session = try browserSession(arguments: fields)
            if ["evaluate", "pdf", "screenshot", "waitForURL"].contains(actionID) {
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
        case "startCapture":
            let capture = try await session.startCapture(includeBodies: fields["includeBodies"]?.boolValue ?? false, reload: fields["reload"]?.boolValue ?? false)
            return .object([
                "active": .bool(true), "includeBodies": .bool(fields["includeBodies"]?.boolValue ?? false),
                "reloaded": .bool(capture.reloaded), "url": capture.url.map { .string($0.absoluteString) } ?? .null,
            ])
        case "markCapture":
            return .object(["marked": .bool(session.markCapture(fields["label"]?.stringValue ?? ""))])
        case "listCapturedEvents":
            return try session.listCapturedEvents(after: fields["after"]?.stringValue, limit: fields["limit"]?.intValue ?? 500,
                                                 origin: fields["origin"]?.stringValue, pathPrefix: fields["pathPrefix"]?.stringValue,
                                                 kinds: fields["kinds"]?.arrayValue?.compactMap(\.stringValue))
        case "readCapturedEvent":
            guard let event = try await session.readCapturedEvent(id: fields["id"]?.stringValue ?? "", bodyMode: fields["bodyMode"]?.stringValue ?? "raw", authorizeSite: authorizeSite) else {
                throw RuntimeError.bridge("ox.web.browser.readCapturedEvent requires a valid captured event id.")
            }
            return event
        case "stopCapture":
            return .object(["stopped": .bool(try await session.stopCapture(discard: fields["discard"]?.boolValue ?? false))])
        default:
            throw Service.InvokeError.unknown("ox.web.browser.\(actionID)")
        }
    }
}
