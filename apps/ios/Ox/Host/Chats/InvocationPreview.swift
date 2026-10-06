import Foundation

nonisolated struct InvocationPreview {
    let value: JSONValue?
    let truncated: Bool
    let bytes: Int

    init(_ value: JSONValue?, limit: Int) {
        var reader = Reader(remaining: max(0, limit))
        self.value = value.flatMap { reader.read($0, depth: 0) }
        truncated = reader.truncated
        bytes = max(0, limit) - reader.remaining
    }

    static func text(_ value: String, limit: Int = 500) -> (value: String, truncated: Bool) {
        let preview = string(value, bytes: limit * 4 + 2, scalars: limit)
        return (preview.value, preview.truncated)
    }

    private static func string(_ value: String, bytes: Int, scalars: Int = .max) -> (value: String, bytes: Int, truncated: Bool) {
        var result = ""
        var used = 2
        var count = 0
        for scalar in value.unicodeScalars {
            let size = switch scalar.value {
            case 0..<32: 6
            case 34, 92: 2
            case 32..<128: 1
            case 128..<2048: 2
            case 2048..<65536: 3
            default: 4
            }
            guard used + size <= bytes, count < scalars else { return (result, used, true) }
            result.unicodeScalars.append(scalar)
            used += size
            count += 1
        }
        return (result, used, false)
    }

    private struct Reader {
        static let preferredKeys = ["url", "title", "filename", "path", "domain", "query", "oxAttachment", "oxProfileID", "items", "truncated", "oldText", "newText", "text", "content"]
        var remaining: Int
        var truncated = false
        var nodes = 0

        mutating func read(_ value: JSONValue, depth: Int) -> JSONValue? {
            guard depth < 8, nodes < 128, remaining >= 2 else { truncated = true; return nil }
            nodes += 1
            switch value {
            case .string(let text):
                let preview = InvocationPreview.string(text, bytes: remaining)
                remaining -= preview.bytes
                truncated = truncated || preview.truncated
                return .string(preview.value)
            case .array(let values):
                remaining -= 2
                var result: [JSONValue] = []
                for value in values.prefix(16) {
                    guard remaining > 2 else { break }
                    remaining -= 1
                    guard let preview = read(value, depth: depth + 1) else { break }
                    result.append(preview)
                }
                truncated = truncated || result.count != values.count
                return .array(result)
            case .object(let fields):
                remaining -= 2
                var result: [String: JSONValue] = [:]
                let preferred = Self.preferredKeys.filter { fields[$0] != nil }
                let keys = preferred + fields.keys.lazy.filter { !Self.preferredKeys.contains($0) }.prefix(32 - preferred.count)
                for key in keys {
                    guard remaining > 6 else { break }
                    let preview = InvocationPreview.string(key, bytes: min(512, remaining - 4))
                    guard !preview.truncated else { truncated = true; continue }
                    remaining -= preview.bytes + 2
                    guard let child = read(fields[key]!, depth: depth + 1) else { break }
                    result[key] = child
                }
                truncated = truncated || result.count != fields.count
                return .object(result)
            case .double(let number) where !number.isFinite:
                truncated = true
                return read(.null, depth: depth)
            default:
                let size = value.jsonString().utf8.count
                guard remaining >= size else { truncated = true; return nil }
                remaining -= size
                return value
            }
        }
    }
}

nonisolated struct InvocationTrace: Equatable, Codable, Sendable {
    static let maximumCalls = 256
    static let maximumPreviewBytes = 64 * 1024
    private(set) var recordedCalls = 0
    private(set) var omittedCalls = 0
    private(set) var previewBytes = 0

    mutating func begin(_ invocation: Invocation) -> Invocation? {
        guard recordedCalls < Self.maximumCalls else { omittedCalls += 1; return nil }
        recordedCalls += 1
        let sources = captureSources(InvocationSources.arguments(invocation.args), replacing: nil)
        let args = capture(invocation.args, limit: 8 * 1024)
        let purpose = InvocationPreview.text(invocation.purpose)
        var result = Invocation(id: invocation.id, name: invocation.name, purpose: purpose.value,
                                args: args.value ?? .object([:]), outcome: invocation.outcome)
        result.sources = sources
        result.preview = Invocation.Preview(argumentsTruncated: args.truncated, resultTruncated: false,
                                            purposeTruncated: purpose.truncated)
        return result
    }

    mutating func finish(_ invocation: inout Invocation, outcome: Invocation.Outcome) {
        switch outcome {
        case .succeeded(let value):
            invocation.sources = captureSources(InvocationSources.result(value, name: invocation.name, sources: invocation.sources),
                                                replacing: invocation.sources)
            let result = capture(value, limit: 4 * 1024)
            invocation.outcome = .succeeded(result.value)
            invocation.preview?.resultTruncated = result.truncated
        case .failed(let error):
            let result = InvocationPreview.text(error)
            invocation.outcome = .failed(result.value)
            invocation.preview?.resultTruncated = result.truncated
        case .running:
            invocation.outcome = .running
        }
    }

    private mutating func captureSources(_ sources: Invocation.Sources?, replacing previous: Invocation.Sources?) -> Invocation.Sources? {
        let previousBytes = InvocationSources.bytes(previous)
        let result = InvocationSources.fitting(sources, limit: min(2 * 1024, Self.maximumPreviewBytes - previewBytes + previousBytes))
        previewBytes += InvocationSources.bytes(result) - previousBytes
        return result
    }

    private mutating func capture(_ value: JSONValue?, limit: Int) -> InvocationPreview {
        let preview = InvocationPreview(value, limit: min(limit, Self.maximumPreviewBytes - previewBytes))
        previewBytes += preview.bytes
        return preview
    }
}

nonisolated private enum InvocationSources {
    static func arguments(_ args: JSONValue) -> Invocation.Sources? {
        let fields = args.objectValue
        let query = fields?["query"]?.stringValue.map { InvocationPreview.text($0, limit: 128).value }
        let domain = complete(fields?["domain"]?.stringValue)
        let links = complete(fields?["url"]?.stringValue).map { [Invocation.Sources.Link(url: $0)] } ?? []
        return Invocation.Sources(query: query, domain: domain, links: links)
    }

    static func result(_ value: JSONValue?, name: String, sources: Invocation.Sources?) -> Invocation.Sources? {
        var result = sources ?? Invocation.Sources()
        if name == Actions.webSearch {
            result.links = (value?.objectValue?["items"]?.arrayValue ?? []).prefix(8).compactMap { item in
                guard let url = complete(item.objectValue?["url"]?.stringValue) else { return nil }
                return Invocation.Sources.Link(url: url, title: item.objectValue?["title"]?.stringValue.map { InvocationPreview.text($0, limit: 128).value })
            }
        } else if name == Actions.webFetch, let url = complete(value?.objectValue?["url"]?.stringValue) {
            result.links = [Invocation.Sources.Link(url: url)]
        }
        return result
    }

    static func fitting(_ sources: Invocation.Sources?, limit: Int) -> Invocation.Sources? {
        guard var result = sources else { return nil }
        while bytes(result) > limit, !result.links.isEmpty { result.links.removeLast() }
        if bytes(result) > limit { result.query = nil }
        if bytes(result) > limit { result.domain = nil }
        guard result.query != nil || result.domain != nil || !result.links.isEmpty, bytes(result) <= limit else { return nil }
        return result
    }

    static func bytes(_ sources: Invocation.Sources?) -> Int {
        guard let sources else { return 0 }
        return (try? JSONEncoder().encode(sources).count) ?? 0
    }

    private static func complete(_ value: String?) -> String? {
        guard let value else { return nil }
        let preview = InvocationPreview(.string(value), limit: 1024)
        return preview.truncated ? nil : preview.value?.stringValue
    }
}
