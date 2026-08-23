import Foundation

nonisolated struct IOSCatalogManifest: Decodable, Sendable {
    struct Icon: Decodable, Sendable {
        let asset: String?
        let system: String?

        var value: ServiceIcon? {
            switch (asset, system) {
            case let (.some(name), nil) where !name.isEmpty: .asset(name)
            case let (nil, .some(name)) where !name.isEmpty: .system(name)
            default: nil
            }
        }

        var jsonValue: JSONValue {
            if let asset { return .object(["asset": .string(asset)]) }
            return .object(["system": .string(system ?? "")])
        }
    }

    struct SupportedIOS: Decodable, Sendable {
        let minimum: String
        let maximum: String?

        var jsonValue: JSONValue {
            var value: [String: JSONValue] = ["minimum": .string(minimum)]
            if let maximum { value["maximum"] = .string(maximum) }
            return .object(value)
        }
    }

    struct ActionLocale: Decodable, Sendable {
        let label: String?
        let description: String?
    }

    struct LocaleOverlay: Decodable, Sendable {
        let name: String?
        let description: String?
        let actions: [String: ActionLocale]?
    }

    let domain: String
    let name: String
    let description: String?
    let icon: Icon
    let permission: NativePermission?
    let supportedIOS: SupportedIOS
    let actions: [JSONValue]
    let locales: [String: LocaleOverlay]?

    var isValid: Bool {
        domain.range(of: #"^ios:[a-z0-9]+(?:[.-][a-z0-9]+)*$"#, options: .regularExpression) != nil
            && !name.isEmpty
            && icon.value != nil
    }

    func localized(_ locale: String?) -> IOSCatalogManifest {
        guard let locale, let overlay = locales?[locale] else { return self }
        let localizedActions = actions.map { action -> JSONValue in
            guard var object = action.objectValue,
                  let id = object["id"]?.stringValue,
                  let actionOverlay = overlay.actions?[id] else { return action }
            if let label = actionOverlay.label { object["label"] = .string(label) }
            if let description = actionOverlay.description { object["description"] = .string(description) }
            return .object(object)
        }
        return IOSCatalogManifest(
            domain: domain,
            name: overlay.name ?? name,
            description: overlay.description ?? description,
            icon: icon,
            permission: permission,
            supportedIOS: supportedIOS,
            actions: localizedActions,
            locales: nil
        )
    }

    var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "domain": .string(domain),
            "name": .string(name),
            "icon": icon.jsonValue,
            "supportedIOS": supportedIOS.jsonValue,
            "actions": .array(actions),
        ]
        if let description { object["description"] = .string(description) }
        if let permission { object["permission"] = .string(permission.rawValue) }
        return .object(object)
    }

    func supports(_ version: OperatingSystemVersion) -> Bool {
        guard let minimum = Self.version(supportedIOS.minimum) else { return false }
        if Self.compare(version, minimum) < 0 { return false }
        guard let rawMaximum = supportedIOS.maximum else { return true }
        guard let maximum = Self.version(rawMaximum) else { return false }
        return Self.compare(version, maximum) <= 0
    }

    private static func version(_ raw: String) -> OperatingSystemVersion? {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
              let major = Int(parts[0]), major > 0,
              parts.dropFirst().allSatisfy({ Int($0) != nil }) else { return nil }
        return OperatingSystemVersion(
            majorVersion: major,
            minorVersion: parts.count > 1 ? Int(parts[1])! : 0,
            patchVersion: parts.count > 2 ? Int(parts[2])! : 0
        )
    }

    private static func compare(_ left: OperatingSystemVersion, _ right: OperatingSystemVersion) -> Int {
        for difference in [
            left.majorVersion - right.majorVersion,
            left.minorVersion - right.minorVersion,
            left.patchVersion - right.patchVersion,
        ] where difference != 0 {
            return difference
        }
        return 0
    }
}

nonisolated struct MCPCatalogManifest: Decodable, Identifiable, Equatable, Sendable {
    struct LocaleOverlay: Decodable, Equatable, Sendable {
        let name: String?
        let description: String?
    }

    let id: String
    let name: String
    let description: String?
    let endpoint: URL
    let transport: RemoteMCPTransport?
    let locales: [String: LocaleOverlay]?

    func localized(_ locale: String?) -> MCPCatalogManifest {
        guard let locale, let overlay = locales?[locale] else { return self }
        return MCPCatalogManifest(
            id: id,
            name: overlay.name ?? name,
            description: overlay.description ?? description,
            endpoint: endpoint,
            transport: transport,
            locales: nil
        )
    }

    var isValid: Bool {
        id.range(of: #"^[a-z0-9]+(?:[.-][a-z0-9]+)*$"#, options: .regularExpression) != nil
            && !name.isEmpty
            && endpoint.scheme == "https"
            && endpoint.host != nil
            && endpoint.user == nil
            && endpoint.password == nil
            && endpoint.fragment == nil
    }
}
