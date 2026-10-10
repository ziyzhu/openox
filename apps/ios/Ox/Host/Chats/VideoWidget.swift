import Foundation

nonisolated struct VideoWidget: Codable, Equatable, Sendable {
    typealias Source = WidgetMediaSource
    let source: Source
}

nonisolated struct ImageWidget: Codable, Equatable, Sendable {
    let source: WidgetMediaSource
}

nonisolated enum WidgetMediaSource: Codable, Equatable, Sendable {
    case remote(String)
    case artifact(Artifact)

    private enum CodingKeys: String, CodingKey {
        case type
        case url
        case artifact
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "remote":
            self = .remote(try container.decode(String.self, forKey: .url))
        case "artifact":
            self = .artifact(try container.decode(Artifact.self, forKey: .artifact))
        case let type:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown media source type '\(type)'"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .remote(url):
            try container.encode("remote", forKey: .type)
            try container.encode(url, forKey: .url)
        case let .artifact(artifact):
            try container.encode("artifact", forKey: .type)
            try container.encode(artifact, forKey: .artifact)
        }
    }

    var artifact: Artifact? {
        guard case let .artifact(artifact) = self else { return nil }
        return artifact
    }
}
