import Foundation

@MainActor
final class NativeServiceOperations {
    struct Prompt {
        let body: String
        let options: [String]
        var purpose: String? = nil
        var resolution: ((String) -> String?)? = nil
    }

    let id: UUID
    let serviceManager: ServiceManager
    let presentations: AppPresentations
    let requireActive: () throws -> Void
    let showBrowser: (Service, UUID) -> Void
    let attachTransient: (TransientAttachment) throws -> Void
    let importArtifact: (TransientAttachment, String) async throws -> Artifact
    let choose: (Prompt) async throws -> String?

    init(
        id: UUID,
        serviceManager: ServiceManager,
        presentations: AppPresentations,
        requireActive: @escaping () throws -> Void,
        showBrowser: @escaping (Service, UUID) -> Void,
        attachTransient: @escaping (TransientAttachment) throws -> Void,
        importArtifact: @escaping (TransientAttachment, String) async throws -> Artifact,
        choose: @escaping (Prompt) async throws -> String?
    ) {
        self.id = id
        self.serviceManager = serviceManager
        self.presentations = presentations
        self.requireActive = requireActive
        self.showBrowser = showBrowser
        self.attachTransient = attachTransient
        self.importArtifact = importArtifact
        self.choose = choose
    }

    private func chooseUser(body: String, options: [String], purpose: String) async throws -> JSONValue? {
        try Task.checkCancellation()
        guard let answer = try await choose(Prompt(body: body, options: options, purpose: purpose)) else { throw CancellationError() }
        return .string(answer)
    }

    func invoke(
        service: Service,
        actionID: String,
        args: JSONValue,
        purpose: String?
    ) async throws -> JSONValue? {
        let browser = service
        let serviceID = service.domain
        if serviceID == "ios:browser" { try requireActive() }
        let fields = args.objectValue ?? [:]
        switch (serviceID, actionID) {
        case ("ios:browser", "navigate"):
            guard let rawURL = fields["url"]?.stringValue,
                  let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https"),
                  url.host?.isEmpty == false,
                  let landed = await serviceManager.browserActionSessions
                    .session(for: browser, ownerID: id)
                    .navigate(url) else {
                throw RuntimeError.bridge("ios:browser:navigate requires an absolute HTTP or HTTPS URL that Browser can load.")
            }
            return .object(["url": .string(landed.absoluteString)])
        case ("ios:browser", "inspect"):
            _ = try await serviceManager.browserActionSessions
                .session(for: browser, ownerID: id)
                .inspectionPage()
            showBrowser(browser, id)
            return .object(["shown": .bool(true)])
        case ("ios:browser", "executeScript"):
            guard let script = fields["script"]?.stringValue else {
                throw RuntimeError.bridge("ios:browser:executeScript requires Browser to be available to an active caller.")
            }
            return try await serviceManager.browserActionSessions
                .session(for: browser, ownerID: id)
                .executeScript(script)
        case ("ios:browser", "screenshot"):
            let screenshot = try await serviceManager.browserActionSessions
                .session(for: browser, ownerID: id)
                .screenshot()
            let artifact: Artifact?
            if let filename = fields["filename"]?.stringValue {
                artifact = try await importArtifact(screenshot.attachment, filename)
            } else {
                try attachTransient(screenshot.attachment)
                artifact = nil
            }
            return .object([
                "url": screenshot.url.map { .string($0.absoluteString) } ?? .null,
                "contentType": .string(screenshot.attachment.mimeType),
                "width": .int(screenshot.width),
                "height": .int(screenshot.height),
                "bytes": .int(screenshot.attachment.data.count),
                "attached": .bool(true),
                "artifact": artifact.map { .string($0.fileName) } ?? .null,
            ])
        case ("ios:browser", "interact"):
            let session = serviceManager.browserActionSessions.session(for: browser, ownerID: id)
            session.stopCapture()
            _ = try await session.clearInjectedScripts()
            showBrowser(browser, id)
            let done = L10n.string("Done")
            let answer = try await chooseUser(
                body: fields["instructions"]?.stringValue
                    ?? L10n.string("Complete the requested step in Browser, then confirm when finished."),
                options: [done, L10n.string("Cancel")],
                purpose: purpose ?? L10n.string("Wait for browser interaction")
            )?.stringValue
            guard answer == done else { throw RuntimeError.bridge("ios:browser:interact: the user cancelled.") }
            return .object(["completed": .bool(true)])
        case ("ios:browser", "injectScript"):
            guard let source = fields["script"]?.stringValue,
                  let domains = fields["domains"]?.arrayValue?.compactMap(\.stringValue) else {
                throw RuntimeError.bridge("ios:browser:injectScript requires a script, target domains, and Browser.")
            }
            let landed = try await serviceManager.browserActionSessions
                .session(for: browser, ownerID: id)
                .injectScript(source, domains: domains)
            return .object(["url": landed.map { .string($0.absoluteString) } ?? .null])
        case ("ios:browser", "clearInjectedScripts"):
            let landed = try await serviceManager.browserActionSessions
                .session(for: browser, ownerID: id)
                .clearInjectedScripts()
            return .object(["url": landed.map { .string($0.absoluteString) } ?? .null])
        case ("ios:browser", "startCapture"):
            let landed = try await serviceManager.browserActionSessions
                .session(for: browser, ownerID: id)
                .startCapture()
            return .object(["url": landed.map { .string($0.absoluteString) } ?? .null])
        case ("ios:browser", "markCapture"):
            guard let label = fields["label"]?.stringValue else {
                throw RuntimeError.bridge("ios:browser:markCapture requires a label and Browser.")
            }
            serviceManager.browserActionSessions.session(for: browser, ownerID: id).markCapture(label)
            return .object(["marked": .bool(true)])
        case ("ios:browser", "listCapturedEvents"):
            let events = serviceManager.browserActionSessions.session(for: browser, ownerID: id).listCapturedEvents()
            return .object(["events": .array(events)])
        case ("ios:browser", "readCapturedEvent"):
            guard let eventID = fields["id"]?.stringValue,
                  let event = serviceManager.browserActionSessions
                    .session(for: browser, ownerID: id)
                    .readCapturedEvent(id: eventID) else {
                throw RuntimeError.bridge("ios:browser:readCapturedEvent requires a valid captured event id.")
            }
            return event
        case ("ios:browser", "stopCapture"):
            serviceManager.browserActionSessions.session(for: browser, ownerID: id).stopCapture()
            return .object(["stopped": .bool(true)])
        case ("ios:location", "current"):
            return try await currentLocation(purpose: purpose)
        case ("ios:location", "searchNearby"):
            return try await searchNearby(
                query: fields["query"]?.stringValue,
                radiusMeters: fields["radiusMeters"]?.doubleValue,
                limit: fields["limit"]?.intValue,
                purpose: purpose
            )
        case ("ios:location", "resolve"):
            return try await resolveLocation(
                query: fields["query"]?.stringValue,
                limit: fields["limit"]?.intValue,
                purpose: purpose
            )
        case ("ios:location", "route"):
            return try await routeLocation(
                destination: fields["destination"]?.stringValue,
                transport: fields["transport"]?.stringValue,
                purpose: purpose
            )
        case ("ios:location", "openInMaps"):
            return try await openLocationInMaps(
                placeID: fields["placeID"]?.stringValue,
                directionsMode: fields["directionsMode"]?.stringValue,
                purpose: purpose
            )
        case ("ios:notifications", "schedule"):
            let schedule = fields["schedule"]?.objectValue ?? [:]
            return try await scheduleNotification(options: .object([
                "title": fields["title"] ?? .null,
                "body": fields["body"] ?? .null,
                "inSeconds": schedule["type"]?.stringValue == "relative" ? schedule["seconds"] ?? .null : .null,
                "fireAt": schedule["type"]?.stringValue == "absolute" ? schedule["dateTime"] ?? .null : .null,
            ]), purpose: purpose)
        case ("ios:notifications", "cancel"):
            return try await cancelNotification(id: fields["id"]?.stringValue)
        case ("ios:calendar", "addEvent"):
            return try await addCalendarEvent(options: fields["options"], purpose: purpose)
        case ("ios:reminders", "add"):
            return try await addReminder(options: fields["options"], purpose: purpose)
        case ("ios:messages", "compose"):
            return try await composeMessage(options: fields["options"], purpose: purpose)
        case ("ios:contacts", "search"):
            return try await searchContacts(query: fields["query"]?.stringValue, purpose: purpose)
        default:
            throw Service.InvokeError.unknown("\(serviceID):\(actionID)")
        }
    }

}
