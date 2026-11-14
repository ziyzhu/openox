import Foundation

nonisolated final class WebFeed: NSObject, XMLParserDelegate {
    struct Result: Sendable {
        let value: JSONValue
        let truncated: Bool
    }

    private struct Element {
        let name: String
        let namespace: String
        let baseURL: URL
        var text = ""
    }

    private static let atomNamespace = "http://www.w3.org/2005/Atom"
    private static let rssNamespace = "http://purl.org/rss/1.0/"
    private var elements: [Element] = []
    private var format: String?
    private var metadata: [String: JSONValue] = [:]
    private var entries: [JSONValue] = []
    private var entry: [String: JSONValue]?
    private var entryDepth: Int?
    private var remainingBytes: Int
    private var truncated = false
    private let sourceURL: URL

    private init(url: URL, maxBytes: Int) {
        sourceURL = url
        remainingBytes = maxBytes
    }

    static func parse(data: Data, url: URL, maxBytes: Int) throws -> Result? {
        let delegate = WebFeed(url: url, maxBytes: maxBytes)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        let valid = parser.parse()
        guard delegate.format != nil else { return nil }
        guard valid else { throw RuntimeError.bridge("ox.web.fetch: malformed RSS or Atom feed") }
        var value = delegate.metadata
        value["entries"] = .array(delegate.entries)
        return Result(value: .object(value), truncated: delegate.truncated)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let namespace = namespaceURI ?? ""
        let inheritedURL = elements.last?.baseURL ?? sourceURL
        let baseURL = attributeDict["xml:base"].flatMap { URL(string: $0, relativeTo: inheritedURL)?.absoluteURL } ?? inheritedURL
        guard elements.count < 256 else { parser.abortParsing(); return }
        elements.append(Element(name: elementName, namespace: namespace, baseURL: baseURL))
        if elements.count == 1 {
            switch (elementName, namespace) {
            case ("rss", ""): format = "rss"
            case ("RDF", "http://www.w3.org/1999/02/22-rdf-syntax-ns#"): format = "rdf"
            case ("feed", Self.atomNamespace): format = "atom"
            default: parser.abortParsing()
            }
        }
        guard format != nil else { return }
        let parent = elements.dropLast().last?.name
        let isEntry = format == "atom"
            ? elementName == "entry" && namespace == Self.atomNamespace && parent == "feed"
            : elementName == "item" && (namespace.isEmpty || namespace == Self.rssNamespace) && (parent == "channel" || parent == "RDF")
        if isEntry, entryDepth == nil {
            entryDepth = elements.count
            entry = [:]
        }
        if namespace == Self.atomNamespace, elementName == "link",
           attributeDict["rel"] == nil || attributeDict["rel"] == "alternate",
           isField, let href = attributeDict["href"], let link = publicLink(href) {
            store("url", link)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard format != nil, !elements.isEmpty else { return }
        let byteCount = string.utf8.count
        let allowed = min(byteCount, max(0, remainingBytes - elements[elements.count - 1].text.utf8.count))
        var prefix = String(decoding: string.utf8.prefix(allowed), as: UTF8.self)
        while prefix.utf8.count > allowed { prefix.removeLast() }
        elements[elements.count - 1].text += prefix
        if allowed < byteCount { truncated = true }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let text = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: text) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let element = elements.last else { return }
        let text = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isField, !text.isEmpty {
            let standard = element.namespace.isEmpty || element.namespace == Self.rssNamespace || element.namespace == Self.atomNamespace
            switch element.name {
            case "title" where standard: store("title", text)
            case "id": store("id", text)
            case "guid" where standard: store("id", text)
            case "link" where standard && format != "atom":
                if let link = publicLink(text) { store("url", link) }
            case "published": store("published", text)
            case "pubDate" where standard: store("published", text)
            case "updated" where standard: store("updated", text)
            case "description": store("summary", text)
            case "summary" where standard: store("summary", text)
            case "content" where standard: store("content", text)
            case "encoded" where element.namespace == "http://purl.org/rss/1.0/modules/content/": store("content", text)
            case "date" where element.namespace == "http://purl.org/dc/elements/1.1/": store("published", text)
            default: break
            }
        }
        if entryDepth == elements.count {
            if let entry, !entry.isEmpty {
                if entries.count < 100 { entries.append(.object(entry)) }
                else { truncated = true }
            }
            entry = nil
            entryDepth = nil
        }
        elements.removeLast()
        let fieldDepth = entryDepth.map { $0 + 1 } ?? (format == "atom" ? 2 : 3)
        if elements.count >= fieldDepth {
            let available = max(0, remainingBytes - elements[elements.count - 1].text.utf8.count)
            elements[elements.count - 1].text += String(decoding: element.text.utf8.prefix(available), as: UTF8.self)
        }
    }

    private var isField: Bool {
        if let entryDepth { return elements.count == entryDepth + 1 }
        if format == "atom" { return elements.count == 2 }
        return elements.count == 3 && elements[1].name == "channel"
    }

    private func publicLink(_ text: String) -> String? {
        guard let url = URL(string: text, relativeTo: elements.last?.baseURL ?? sourceURL)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil else { return nil }
        return url.absoluteString
    }

    private func store(_ key: String, _ value: String) {
        guard entryDepth == nil || entries.count < 100 else { truncated = true; return }
        var bounded = String(decoding: value.utf8.prefix(remainingBytes), as: UTF8.self)
        while bounded.utf8.count > remainingBytes { bounded.removeLast() }
        remainingBytes -= bounded.utf8.count
        if bounded.utf8.count < value.utf8.count { truncated = true }
        if entryDepth != nil { entry?[key] = .string(bounded) }
        else { metadata[key] = .string(bounded) }
    }
}
