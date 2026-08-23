import Foundation

extension Chat {
    public func presentShoveler(value: JSONValue?, purpose: String) async throws -> JSONValue? {
        guard let value else { throw RuntimeError.bridge("ox.widget.shoveler: widget is required") }
        let data = try JSONEncoder().encode(value)
        let shoveler: Shoveler
        do {
            let decoder = JSONDecoder()
            decoder.userInfo[.profileScope] = scope
            shoveler = try decoder.decode(Shoveler.self, from: data)
        } catch {
            throw RuntimeError.bridge("ox.widget.shoveler: invalid widget data")
        }
        guard !shoveler.cards.isEmpty else {
            throw RuntimeError.bridge("ox.widget.shoveler: cards must contain at least one card")
        }
        for (index, card) in shoveler.cards.enumerated() {
            guard card.image != nil || card.title != nil || card.description != nil || card.badge != nil else {
                throw RuntimeError.bridge("ox.widget.shoveler: cards[\(index)] must contain display content")
            }
            if let image = card.image {
                guard let components = URLComponents(string: image),
                      components.scheme == "https",
                      components.host?.isEmpty == false,
                      components.user == nil,
                      components.password == nil else {
                    throw RuntimeError.bridge("ox.widget.shoveler: cards[\(index)].image must be a public HTTPS URL")
                }
            }
            if let artifact = card.artifact, !artifact.exists {
                throw RuntimeError.bridge("ox.widget.shoveler: cards[\(index)].artifact does not exist: \(artifact.fileName)")
            }
        }
        let args: JSONValue = .object([
            "cards": .int(shoveler.cards.count),
        ])
        return try await trackedEffect(.widgetShoveler, args, purpose: purpose, apply: embedShoveler) {
            (.null, shoveler)
        }
    }

    public func presentVideo(value: JSONValue?, purpose: String) async throws -> JSONValue? {
        guard let fields = value?.objectValue,
              let sourceValue = fields["video"]?.stringValue else {
            throw RuntimeError.bridge("ox.widget.video: video is required")
        }
        let source: VideoWidget.Source
        if let components = URLComponents(string: sourceValue), components.scheme != nil {
            guard components.scheme == "https",
                  components.host?.isEmpty == false,
                  components.user == nil,
                  components.password == nil else {
                throw RuntimeError.bridge("ox.widget.video: video must be a public HTTPS URL or an existing video artifact filename")
            }
            source = .remote(sourceValue)
        } else {
            let artifact = try await repository.artifact(named: sourceValue, in: scope)
            guard artifact.exists else {
                throw RuntimeError.bridge("ox.widget.video: video artifact does not exist: \(sourceValue)")
            }
            guard artifact.isVideo else {
                throw RuntimeError.bridge("ox.widget.video: artifact is not a video: \(artifact.fileName)")
            }
            source = .artifact(artifact)
        }
        let video = VideoWidget(source: source)
        let args: JSONValue = .object([
            "video": .string(sourceValue),
        ])
        return try await trackedEffect(.widgetVideo, args, purpose: purpose, apply: embedVideo) {
            (.null, video)
        }
    }
}
