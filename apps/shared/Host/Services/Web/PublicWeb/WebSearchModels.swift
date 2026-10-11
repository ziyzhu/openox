import Foundation

nonisolated enum WebSearchRequestError: LocalizedError, Sendable {
    case invalidQuery

    var errorDescription: String? {
        "ox.web.search: query must contain 1–500 characters"
    }
}

nonisolated struct WebSearchRequest: Sendable {
    let query: String

    init(query: String) throws {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 500 else { throw WebSearchRequestError.invalidQuery }
        self.query = query
    }
}

nonisolated struct WebSearchResult: Sendable {
    let id: String
    let title: String
    let url: String
    let snippet: String
    let site: String
    let publishedAt: String?
    let providers: [String]

    var json: JSONValue {
        .object([
            "id": .string(id),
            "title": .string(title),
            "url": .string(url),
            "snippet": .string(snippet),
            "site": .string(site),
            "publishedAt": publishedAt.map(JSONValue.string) ?? .null,
            "providers": .array(providers.map(JSONValue.string)),
        ])
    }
}

nonisolated struct WebSearchPage: Sendable {
    let query: String
    let items: [WebSearchResult]
    let provider: String
    let providers: [String]

    var json: JSONValue {
        .object([
            "query": .string(query),
            "items": .array(items.map(\.json)),
            "provider": .string(provider),
            "providers": .array(providers.map(JSONValue.string)),
        ])
    }
}
