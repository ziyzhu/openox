import AppIntents
import Foundation

struct OxChatEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Ox Chat",
        numericFormat: "\(placeholder: .int) Ox chats"
    )
    static let defaultQuery = OxChatQuery()

    let id: UUID
    let title: String
    let preview: String?
    let activityDate: Date

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: preview.map { "\($0)" },
            image: .init(systemName: "bubble.left.and.text.bubble.right")
        )
    }

    init(_ meta: ChatMeta) {
        id = meta.id
        title = meta.displayTitle
        preview = meta.preview
        activityDate = meta.activityDate
    }
}

struct OxChatQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [OxChatEntity] {
        let requested = Set(identifiers)
        return try await entities().filter { requested.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [OxChatEntity] {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return try await entities() }
        return try await entities().filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || $0.preview?.localizedCaseInsensitiveContains(needle) == true
        }
    }

    func suggestedEntities() async throws -> [OxChatEntity] {
        try await entities()
    }

    @MainActor
    private func entities() async throws -> [OxChatEntity] {
        let client = try await OxIntentSupport.readyClient()
        return client.chats.orderedSummaries.prefix(20).map(OxChatEntity.init)
    }
}
