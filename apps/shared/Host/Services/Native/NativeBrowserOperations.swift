import Foundation

extension NativeServiceOperations {
    func invokeBrowserOperation(actionID: String, args: JSONValue, purpose: String?) async throws -> JSONValue? {
        let fields = args.objectValue ?? [:]
        switch actionID {
        case "open":
            return try await openBrowserPage(url: fields["url"]?.stringValue ?? "")
        case "list":
            return try await listBrowserPages(includeFrames: fields["includeFrames"]?.boolValue ?? false)
        case "close":
            let page = try serviceManager.browserSessions.requirePage(fields["pageId"]?.stringValue ?? "", scopeID: id)
            guard serviceManager.actionScheduler.isIdle(page) else {
                throw OxFunctionError(code: "page_busy", message: "The selected page is busy.", recovery: "Wait for its active operation or user handoff to finish before closing it.")
            }
            serviceManager.browserActionSessions.closePage(page)
            return .object(["closed": .bool(true)])
        default:
            let session = try browserSession(arguments: fields)
            if ["executeScript", "exportPdf", "stopLoading", "waitForNavigation"].contains(actionID) {
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
        case "navigate":
            guard let raw = fields["url"]?.stringValue, let url = URL(string: raw), BrowserNavigation.allowsServiceNavigation(url) else {
                throw RuntimeError.bridge("ox.web.browser.navigate requires an absolute public HTTPS URL. Simulator builds also allow loopback HTTP.")
            }
            let landed = try await session.navigate(url)
            return .object(["url": .string(landed.absoluteString)])
        case "reload":
            let landed = try await session.reload(fromOrigin: fields["fromOrigin"]?.boolValue ?? false)
            return .object(["url": landed.map { .string($0.absoluteString) } ?? .null])
        case "stopLoading":
            let url = try await session.stopLoading()
            return .object(["stopped": .bool(true), "url": url.map { .string($0.absoluteString) } ?? .null])
        case "goBack", "goForward":
            let landed = actionID == "goBack" ? try await session.goBack() : try await session.goForward()
            return .object(["navigated": .bool(landed != nil), "url": landed.map { .string($0.absoluteString) } ?? .null])
        case "getNavigationHistory":
            return try await session.navigationHistory()
        case "getPageState":
            return try await session.pageState(selector: fields["selector"]?.stringValue, frameID: fields["frameId"]?.stringValue, authorizeSite: authorizeSite)
        case "waitForNavigation":
            let landed = try await session.waitForNavigation(timeoutMilliseconds: fields["timeoutMs"]?.intValue ?? 15_000)
            return .object(["url": landed.map { .string($0.absoluteString) } ?? .null])
        case "executeScript":
            return try await session.executeScript(fields["script"]?.stringValue ?? "", frameID: fields["frameId"]?.stringValue, authorizeSite: authorizeSite)
        case "exportPdf":
            let pdf = try await session.exportPDF(authorizeSite: authorizeSite)
            let file: FileItem?
            if let filename = fields["filename"]?.stringValue {
                file = try await importFile(pdf.attachment, filename)
            } else {
                try attachTransient(pdf.attachment)
                file = nil
            }
            return .object([
                "url": pdf.url.map { .string($0.absoluteString) } ?? .null,
                "contentType": .string(pdf.attachment.mimeType), "pages": .int(pdf.pages), "bytes": .int(pdf.attachment.data.count),
                "attached": .bool(true), "file": file.map { .string($0.fileName) } ?? .null,
            ])
        case "injectScript":
            let landed = try await session.injectScript(fields["script"]?.stringValue ?? "", domains: fields["domains"]?.arrayValue?.compactMap(\.stringValue) ?? [], authorizeSite: authorizeSite)
            return .object(["url": landed.map { .string($0.absoluteString) } ?? .null])
        case "clearScripts":
            let landed = try await session.clearScripts()
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
