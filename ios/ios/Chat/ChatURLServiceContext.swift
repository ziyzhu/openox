import Foundation

@MainActor
enum ChatURLServiceContext {
    private static let maximumURLs = 12
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func transform(
        _ messages: [Message],
        serviceManager: ServiceManager,
        chatID: UUID
    ) -> [Message] {
        guard serviceManager.monoRepositoryState == .ready,
              let range = relevantRange(in: messages),
              let target = range.last else { return messages }
        var urls: [URL] = []
        var seen = Set<String>()
        for index in range {
            collectURLs(from: messages[index], into: &urls, seen: &seen)
            if urls.count >= maximumURLs { break }
        }
        guard !urls.isEmpty else { return messages }
        var matched = 0
        let relations = urls.prefix(maximumURLs).map { url in
            let services = serviceManager.relatedWebServices(for: url).prefix(3).map { service in
                let attachment = serviceManager.isAttached(domain: service.domain, to: chatID)
                    ? "attached"
                    : "not-attached"
                return "- \(lineField(service.domain)) | \(lineField(service.title)) | \(attachment)"
            }
            matched += services.count
            return ([url.absoluteString] + (services.isEmpty ? ["- no-related-services"] : services))
                .joined(separator: "\n")
        }
        let metadata = """
        <url-relations provenance="runtime-generated">
        \(relations.joined(separator: "\n\n"))
        </url-relations>
        """
        var transformed = messages
        switch transformed[target] {
        case .user(var user):
            user.transientContext = [user.transientContext, metadata]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            transformed[target] = .user(user)
        case .toolResult(var result):
            result.content.append(.text(TextContent("\n\n\(metadata)")))
            transformed[target] = .toolResult(result)
        case .assistant:
            return messages
        }
        Log.session.debug("ChatURLServiceContext.transform chat=\(chatID) urls=\(relations.count) matches=\(matched)")
        return transformed
    }

    private static func lineField(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .replacingOccurrences(of: "|", with: "/")
    }

    private static func relevantRange(in messages: [Message]) -> ClosedRange<Int>? {
        guard let last = messages.indices.last else { return nil }
        switch messages[last] {
        case .user:
            var first = last
            while first > messages.startIndex {
                guard case .user = messages[messages.index(before: first)] else { break }
                first = messages.index(before: first)
            }
            return first...last
        case .toolResult:
            let first = messages[...last].lastIndex { message in
                if case .assistant = message { true } else { false }
            } ?? last
            return first...last
        case .assistant:
            return nil
        }
    }

    private static func collectURLs(from message: Message, into urls: inout [URL], seen: inout Set<String>) {
        switch message {
        case .user(let user):
            for block in user.content {
                if case .text(let text) = block { collectURLs(from: text.text, into: &urls, seen: &seen) }
            }
        case .assistant(let assistant):
            for block in assistant.content {
                if case .toolCall(let call) = block { collectURLs(from: call.arguments, into: &urls, seen: &seen) }
            }
        case .toolResult(let result):
            for block in result.content {
                if case .text(let text) = block { collectURLs(from: text.text, into: &urls, seen: &seen) }
            }
        }
    }

    private static func collectURLs(from value: JSONValue, into urls: inout [URL], seen: inout Set<String>) {
        switch value {
        case .string(let string):
            collectURLs(from: string, into: &urls, seen: &seen)
        case .array(let values):
            for value in values { collectURLs(from: value, into: &urls, seen: &seen) }
        case .object(let fields):
            for key in fields.keys.sorted() {
                if let value = fields[key] { collectURLs(from: value, into: &urls, seen: &seen) }
            }
        case .null, .bool, .int, .double:
            break
        }
    }

    private static func collectURLs(from text: String, into urls: inout [URL], seen: inout Set<String>) {
        guard urls.count < maximumURLs, let detector else { return }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        detector.enumerateMatches(in: text, range: range) { result, _, stop in
            guard let url = result?.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return }
            let value = url.absoluteString
            if seen.insert(value).inserted { urls.append(url) }
            if urls.count >= maximumURLs { stop.pointee = true }
        }
    }
}
