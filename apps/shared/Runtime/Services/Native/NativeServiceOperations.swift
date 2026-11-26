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
    let showServicePage: (Service, BrowserSession) throws -> Void
    let attachTransient: (TransientAttachment) throws -> Void
    let importFile: (TransientAttachment, String) async throws -> FileItem
    let choose: (Prompt) async throws -> String?
    let authorizeBrowserSite: (String, String?) async throws -> Void

    init(
        id: UUID,
        serviceManager: ServiceManager,
        presentations: AppPresentations,
        requireActive: @escaping () throws -> Void,
        showServicePage: @escaping (Service, BrowserSession) throws -> Void,
        attachTransient: @escaping (TransientAttachment) throws -> Void,
        importFile: @escaping (TransientAttachment, String) async throws -> FileItem,
        choose: @escaping (Prompt) async throws -> String?,
        authorizeBrowserSite: @escaping (String, String?) async throws -> Void
    ) {
        self.id = id
        self.serviceManager = serviceManager
        self.presentations = presentations
        self.requireActive = requireActive
        self.showServicePage = showServicePage
        self.attachTransient = attachTransient
        self.importFile = importFile
        self.choose = choose
        self.authorizeBrowserSite = authorizeBrowserSite
    }

    func invoke(service: Service, actionID: String, args: JSONValue, purpose: String?) async throws -> JSONValue? {
        if service.domain == BrowserFunctionCatalog.internalDomain {
            return try await invokeBrowserOperation(actionID: actionID, args: args, purpose: purpose)
        }
        let fields = args.objectValue ?? [:]
        switch (service.domain, actionID) {
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
            return try await resolveLocation(query: fields["query"]?.stringValue, limit: fields["limit"]?.intValue, purpose: purpose)
        case ("ios:location", "route"):
            return try await routeLocation(destination: fields["destination"]?.stringValue, transport: fields["transport"]?.stringValue, purpose: purpose)
        case ("ios:location", "openInMaps"):
            return try await openLocationInMaps(placeID: fields["placeID"]?.stringValue, directionsMode: fields["directionsMode"]?.stringValue, purpose: purpose)
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
            throw Service.InvokeError.unknown("\(service.domain):\(actionID)")
        }
    }
}
