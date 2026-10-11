import Foundation

nonisolated struct ServiceInspectorLink: Codable, Equatable, Sendable {
    let domain: String
    let serviceName: String
}

nonisolated enum ServiceControl: Equatable, Sendable {
    case signIn(domain: String, serviceName: String?)
    case botControl(domain: String, serviceName: String?, args: JSONValue)
    case payment(domain: String, serviceName: String?, args: JSONValue)

    var domain: String {
        switch self {
        case .signIn(let domain, _), .botControl(let domain, _, _), .payment(let domain, _, _): domain
        }
    }
}

nonisolated extension ServiceControl: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case domain
        case serviceName
        case args
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let domain = try values.decode(String.self, forKey: .domain)
        let serviceName = try values.decodeIfPresent(String.self, forKey: .serviceName)
        switch try values.decode(String.self, forKey: .type) {
        case "signIn":
            self = .signIn(domain: domain, serviceName: serviceName)
        case "botControl":
            self = .botControl(
                domain: domain,
                serviceName: serviceName,
                args: try values.decode(JSONValue.self, forKey: .args)
            )
        case "payment":
            self = .payment(
                domain: domain,
                serviceName: serviceName,
                args: try values.decode(JSONValue.self, forKey: .args)
            )
        case let type:
            throw DecodingError.dataCorruptedError(forKey: .type, in: values, debugDescription: "Unknown service control '\(type)'")
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .signIn(domain, serviceName):
            try values.encode("signIn", forKey: .type)
            try values.encode(domain, forKey: .domain)
            try values.encodeIfPresent(serviceName, forKey: .serviceName)
        case let .botControl(domain, serviceName, args):
            try values.encode("botControl", forKey: .type)
            try values.encode(domain, forKey: .domain)
            try values.encodeIfPresent(serviceName, forKey: .serviceName)
            try values.encode(args, forKey: .args)
        case let .payment(domain, serviceName, args):
            try values.encode("payment", forKey: .type)
            try values.encode(domain, forKey: .domain)
            try values.encodeIfPresent(serviceName, forKey: .serviceName)
            try values.encode(args, forKey: .args)
        }
    }
}
