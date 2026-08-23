import Foundation

nonisolated enum LogPrivacy {
    static func url(_ raw: String) -> String {
        guard let components = URLComponents(string: raw) else {
            return bounded(redactPath(String(raw.prefix { $0 != "?" && $0 != "#" })), limit: 240)
        }
        let authority = [components.scheme.map { "\($0)://" }, components.host]
            .compactMap { $0 }
            .joined()
        let port = components.port.map { ":\($0)" } ?? ""
        let path = redactPath(components.percentEncodedPath)
        let query = components.queryItems.map { items in
            let keys = Array(Set(items.map { redactSegment($0.name) })).sorted().joined(separator: ",")
            return keys.isEmpty ? "" : "?keys=\(keys)"
        } ?? ""
        let value = "\(authority)\(port)\(path)\(query)"
        return value.isEmpty ? "?" : bounded(value, limit: 240)
    }

    static func text(_ raw: String, limit: Int = 512) -> String {
        let replacements = [
            (regex("(?i)\\bBearer\\s+[A-Za-z0-9._~+/=-]+"), "Bearer <redacted>"),
            (regex("(?i)(authorization|cookie|set-cookie|access[_-]?token|refresh[_-]?token|api[_-]?key|password|secret)(\\s*[:=]\\s*)[\\\"']?[^\\s,\\\"'};]+"), "$1$2<redacted>"),
            (regex("\\bsk-[A-Za-z0-9_-]{12,}"), "sk-<redacted>"),
            (regex("\\b(?:gh[pousr]_[A-Za-z0-9]{12,}|github_pat_[A-Za-z0-9_]{12,})"), "github_<redacted>"),
            (regex("\\bAIza[A-Za-z0-9_-]{12,}"), "AIza<redacted>")
        ]
        let linked = redactURLs(in: raw)
        let scrubbed = replacements.reduce(linked) { value, replacement in
            replacement.0.stringByReplacingMatches(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value),
                withTemplate: replacement.1
            )
        }
        return bounded(scrubbed, limit: limit)
    }

    private static func redactURLs(in raw: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return raw }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let matches = detector.matches(in: raw, range: range)
        return matches.reversed().reduce(raw) { value, match in
            guard let swiftRange = Range(match.range, in: value), let link = match.url?.absoluteString else { return value }
            var next = value
            next.replaceSubrange(swiftRange, with: url(link))
            return next
        }
    }

    private static func bounded(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return "\(value.prefix(limit))… chars=\(value.count)"
    }

    private static func redactPath(_ value: String) -> String {
        value.split(separator: "/", omittingEmptySubsequences: false)
            .map { redactSegment(String($0)) }
            .joined(separator: "/")
    }

    private static func redactSegment(_ value: String) -> String {
        value.count > 32 ? "<redacted>" : value
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }
}
