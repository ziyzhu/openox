import Foundation

extension Chat {
    private func performIOSServiceAction<T>(
        _ action: String,
        _ args: JSONValue,
        purpose: String? = nil,
        _ body: () async throws -> T
    ) async throws -> T {
        try await body()
    }

    public func currentLocation(purpose: String?) async throws -> JSONValue? {
        try requireIOSService("ios:location")
        return try await performIOSServiceAction("location.current", .object([:]), purpose: purpose) {
            let place = try await LocationProvider.shared.current()
            Log.session.info("bridge.location.current city=\(place.city ?? "?") region=\(place.region ?? "?") country=\(place.countryCode ?? "?")")
            return try Self.encodeToJSON(place)
        }
    }

    public func searchNearby(
        query: String?,
        radiusMeters: Double?,
        limit: Int?,
        purpose: String?
    ) async throws -> JSONValue? {
        try requireIOSService("ios:location")
        guard let query else { throw RuntimeError.bridge("ios:location:searchNearby: 'query' is required.") }
        let radius = radiusMeters ?? 5_000
        let limit = limit ?? 10
        return try await performIOSServiceAction("location.searchNearby", .object([
            "query": .string(query),
            "radiusMeters": .double(radius),
            "limit": .int(limit),
        ]), purpose: purpose) {
            let places = try await MapProvider.shared.searchNearby(query: query, radiusMeters: radius, limit: limit)
            return try Self.encodeToJSON(places)
        }
    }

    public func resolveLocation(query: String?, limit: Int?, purpose: String?) async throws -> JSONValue? {
        try requireIOSService("ios:location")
        guard let query else { throw RuntimeError.bridge("ios:location:resolve: 'query' is required.") }
        let limit = limit ?? 5
        return try await performIOSServiceAction("location.resolve", .object([
            "query": .string(query),
            "limit": .int(limit),
        ]), purpose: purpose) {
            let places = try await MapProvider.shared.resolve(query: query, limit: limit)
            return try Self.encodeToJSON(places)
        }
    }

    public func routeLocation(destination: String?, transport: String?, purpose: String?) async throws -> JSONValue? {
        try requireIOSService("ios:location")
        guard let destination else { throw RuntimeError.bridge("ios:location:route: 'destination' is required.") }
        let transport = transport ?? "automobile"
        return try await performIOSServiceAction("location.route", .object([
            "destination": .string(destination),
            "transport": .string(transport),
        ]), purpose: purpose) {
            let route = try await MapProvider.shared.route(destination: destination, transport: transport)
            return try Self.encodeToJSON(route)
        }
    }

    public func openLocationInMaps(placeID: String?, directionsMode: String?, purpose: String?) async throws -> JSONValue? {
        try requireIOSService("ios:location")
        guard let placeID else { throw RuntimeError.bridge("ios:location:openInMaps: 'placeID' is required.") }
        var args: [String: JSONValue] = ["placeID": .string(placeID)]
        if let directionsMode { args["directionsMode"] = .string(directionsMode) }
        return try await performIOSServiceAction("location.openInMaps", .object(args), purpose: purpose) {
            let result = try await MapProvider.shared.openInMaps(placeID: placeID, directionsMode: directionsMode)
            return try Self.encodeToJSON(result)
        }
    }

    public func scheduleNotification(options: JSONValue?, purpose: String?) async throws -> JSONValue? {
        try requireIOSService("ios:notifications")
        let opts = options?.objectValue ?? [:]
        guard let title = opts["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw RuntimeError.bridge("ios:notifications:schedule: 'title' is required.")
        }
        return try await performIOSServiceAction("notifications.schedule", .object(["title": .string(title)]), purpose: purpose) {
            let scheduled = try await NotificationProvider.shared.schedule(
                title: title,
                body: opts["body"]?.stringValue,
                fireAt: opts["fireAt"]?.stringValue,
                inSeconds: opts["inSeconds"]?.doubleValue
            )
            Log.session.info("bridge.notification.schedule id=\(scheduled.id) fireAt=\(scheduled.fireAt)")
            return try Self.encodeToJSON(scheduled)
        }
    }

    public func cancelNotification(id: String?) async throws -> JSONValue? {
        try requireIOSService("ios:notifications")
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            throw RuntimeError.bridge("ios:notifications:cancel: 'id' is required.")
        }
        return try await performIOSServiceAction("notifications.cancel", .object(["id": .string(id)])) {
            Log.session.info("bridge.notification.cancel id=\(id)")
            NotificationProvider.shared.cancel(id: id)
            return .null
        }
    }

    public func addCalendarEvent(options: JSONValue?, purpose: String?) async throws -> JSONValue? {
        try requireIOSService("ios:calendar")
        let opts = options?.objectValue ?? [:]
        guard let title = opts["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw RuntimeError.bridge("ios:calendar:addEvent: 'title' is required.")
        }
        return try await performIOSServiceAction("calendar.addEvent", .object(["title": .string(title)]), purpose: purpose) {
            let saved = try await CalendarProvider.shared.addEvent(
                title: title,
                start: opts["start"]?.stringValue,
                end: opts["end"]?.stringValue,
                location: opts["location"]?.stringValue,
                notes: opts["notes"]?.stringValue
            )
            Log.session.info("bridge.calendar.event id=\(saved.id) start=\(saved.start)")
            return try Self.encodeToJSON(saved)
        }
    }

    public func addReminder(options: JSONValue?, purpose: String?) async throws -> JSONValue? {
        try requireIOSService("ios:reminders")
        let opts = options?.objectValue ?? [:]
        guard let title = opts["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw RuntimeError.bridge("ios:reminders:add: 'title' is required.")
        }
        return try await performIOSServiceAction("reminders.add", .object(["title": .string(title)]), purpose: purpose) {
            let saved = try await CalendarProvider.shared.addReminder(
                title: title,
                due: opts["due"]?.stringValue,
                notes: opts["notes"]?.stringValue
            )
            Log.session.info("bridge.reminder.add id=\(saved.id) due=\(saved.due ?? "none")")
            return try Self.encodeToJSON(saved)
        }
    }

    public func composeMessage(options: JSONValue?, purpose: String?) async throws -> JSONValue? {
        try requireIOSService("ios:messages")
        let opts = options?.objectValue ?? [:]
        let queries: [String] = {
            if let one = opts["to"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !one.isEmpty {
                return [one]
            }
            if let many = opts["to"]?.arrayValue {
                return many.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
            return []
        }()
        let body = opts["body"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stepArgs: JSONValue = .object([
            "to": .string(queries.joined(separator: ", ")),
            "body": .string(body ?? ""),
        ])
        return try await performIOSServiceAction("messages.compose", stepArgs, purpose: purpose) {
            guard self.presentations.messages.canSend else { throw MessageComposeError.unavailable }
            let recipients = try await self.resolveRecipients(queries)
            let toDisplay = queries.joined(separator: ", ")
            let header = toDisplay.isEmpty
                ? L10n.string( "Send a message")
                : L10n.string( "Message \(toDisplay)")
            let preview = (body?.isEmpty == false) ? "\(header)\n\n\(body!)" : header
            let open = L10n.string( "Open Messages")
            let dismiss = L10n.string( "Not now")
            let choice = await self.awaitPrompt(
                prompt: preview,
                options: [open, dismiss],
                presentation: .application,
                resolution: { $0 == open ? L10n.string( "Opened Messages") : L10n.string( "Dismissed") }
            )
            guard choice == open else {
                Log.session.info("bridge.message.compose dismissed before composer")
                return try Self.encodeToJSON(["disposition": MessageDisposition.cancelled.rawValue])
            }
            let disposition = try await self.presentations.messages.present(recipients: recipients, body: body)
            Log.session.info("bridge.message.compose recipients=\(recipients.count) disposition=\(disposition.rawValue)")
            return try Self.encodeToJSON(["disposition": disposition.rawValue])
        }
    }

    public func searchContacts(query: String?, purpose: String?) async throws -> JSONValue? {
        try requireIOSService("ios:contacts")
        guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            throw RuntimeError.bridge("ios:contacts:search: 'query' is required.")
        }
        return try await performIOSServiceAction("contacts.search", .object(["query": .string(query)]), purpose: purpose) {
            let cards = try await ContactsProvider.shared.search(query: query)
            Log.session.info("bridge.contact.search query=\(query) cards=\(cards.count)")
            return try Self.encodeToJSON(cards)
        }
    }

    func readPrivateData(
        _ request: PrivateDataRequest,
        action: String,
        args: JSONValue,
        purpose: String?,
        read: @escaping () async throws -> JSONValue
    ) async throws -> JSONValue? {
        return try await performIOSServiceAction(action, args, purpose: purpose) {
            try await authorizePrivateData(request)
            return try await read()
        }
    }

    private func authorizePrivateData(_ request: PrivateDataRequest) async throws {
        try await PrivateDataAccess(host: self).authorize(request)
    }

    func requireIOSService(_ id: String) throws {
        guard attachedServices.contains(where: { $0.domain == id }) else {
            throw RuntimeError.bridge("\(id) isn't attached to this chat. Find and attach it before using this iOS service.")
        }
    }

    private func resolveRecipients(_ queries: [String]) async throws -> [String] {
        var resolved: [String] = []
        for query in queries {
            if Self.looksLikePhoneNumber(query) {
                resolved.append(query)
                continue
            }
            let numbers = Array(Set(try await ContactsProvider.shared.resolve(name: query).map { $0.number }))
            if numbers.count == 1 {
                resolved.append(numbers[0])
            } else {
                Log.session.info("message.resolve query=\(query) numbers=\(numbers.count) ambiguous; leaving recipient for the user to pick")
            }
        }
        return resolved
    }

    private static func looksLikePhoneNumber(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "+0123456789 ()-.")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) } && value.filter(\.isNumber).count >= 5
    }
}
