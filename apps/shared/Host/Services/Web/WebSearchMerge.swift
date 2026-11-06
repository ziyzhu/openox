import Foundation

extension OxSearch {
    static func canonicalSearchURL(_ value: String?) -> String? {
        guard let value, let url = URL(string: value, encodingInvalidCharacters: false),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.port.map({ (0...65535).contains($0) }) ?? true else { return nil }
        components.scheme = scheme
        components.host = host.lowercased()
        if components.port == (scheme == "https" ? 443 : 80) { components.port = nil }
        if let query = components.percentEncodedQuery {
            let parts = query.components(separatedBy: "&")
            let retained = parts.filter { part in
                let encodedName = String(part.prefix { $0 != "=" })
                let name = (encodedName.removingPercentEncoding ?? encodedName).lowercased()
                return !name.hasPrefix("utm_") && !["gclid", "dclid", "fbclid", "msclkid"].contains(name)
            }
            if retained.count != parts.count {
                components.percentEncodedQuery = retained.isEmpty ? nil : retained.joined(separator: "&")
            }
        }
        return components.string
    }

    private struct SearchSource {
        let service: String
        let rank: Int
        let title: String
        let url: JSONValue
        let snippet: JSONValue

        var json: JSONValue {
            .object(["service": .string(service), "rank": .int(rank)])
        }

        static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.service != rhs.service { return lhs.service < rhs.service }
            if lhs.url != rhs.url { return (lhs.url.stringValue ?? "") < (rhs.url.stringValue ?? "") }
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            return (lhs.snippet.stringValue ?? "") < (rhs.snippet.stringValue ?? "")
        }
    }

    static func mergeSearchResults(_ pages: [JSONValue], weights: [String: Double] = [:]) -> [JSONValue] {
        var canonicalGroups: [String: [SearchSource]] = [:]
        var groups: [[SearchSource]] = []
        for page in pages {
            guard let service = page.objectValue?["service"]?.stringValue else { continue }
            for (index, item) in (page.objectValue?["items"]?.arrayValue ?? []).enumerated() {
                let fields = item.objectValue ?? [:]
                let source = SearchSource(service: service, rank: index + 1, title: fields["title"]?.stringValue ?? "", url: fields["url"] ?? .null, snippet: fields["snippet"] ?? .null)
                if let canonical = canonicalSearchURL(source.url.stringValue) {
                    canonicalGroups[canonical, default: []].append(source)
                } else {
                    groups.append([source])
                }
            }
        }
        groups.append(contentsOf: canonicalGroups.values)
        let ranked = groups.map { sources -> (score: Double, display: SearchSource, sources: [SearchSource]) in
            let sources = sources.sorted(by: SearchSource.precedes)
            var bestRanks: [String: Int] = [:]
            for source in sources { bestRanks[source.service] = min(bestRanks[source.service] ?? source.rank, source.rank) }
            let score = bestRanks.sorted { $0.key < $1.key }.reduce(0.0) { score, contribution in
                let weight = weights[contribution.key] ?? 1
                return score + (weight.isFinite && weight >= 0 ? weight : 1) / Double(60 + contribution.value)
            }
            return (score, sources[0], sources)
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return SearchSource.precedes(lhs.display, rhs.display)
        }
        return ranked.map { result in
            .object(["score": .double(result.score), "sources": .array(result.sources.map(\.json))])
        }
    }
}
