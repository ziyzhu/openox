import Foundation

nonisolated enum DefuddleError: LocalizedError, Sendable {
    case emptyDocument
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .emptyDocument: "ox.web.fetch: HTML document has no body"
        case .emptyContent: "ox.web.fetch: HTML document has no readable content"
        }
    }
}

nonisolated enum Defuddle {
    static func markdown(html: String, baseURL: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try convert(html: html, baseURL: baseURL)
        }.value
    }

    private static let negativeTerms = [
        "advert", "banner", "breadcrumb", "cookie", "copyright", "footer", "header", "login",
        "author", "byline", "menu", "nav", "newsletter", "pagination", "popular", "post-date", "privacy", "promo", "recommend",
        "related", "share", "sidebar", "social", "sponsor", "subscribe", "trending", "widget",
    ]

    private static let positiveTerms = [
        "article", "body", "content", "entry", "main", "markdown", "post", "story",
    ]

    private static let discardedTags = Set([
        "applet", "base", "button", "canvas", "dialog", "embed", "fieldset", "footer", "form",
        "frame", "frameset", "link", "meta", "nav", "noscript", "object", "script", "select",
        "style", "template", "textarea",
    ])

    private static func convert(html: String, baseURL: URL) throws -> String {
        let document = HTMLParser.parse(html)
        let title = document.elements.first(where: {
            $0.tag == "meta" && $0.attribute("property").lowercased() == "og:title"
        })?.attribute("content") ?? document.first(where: { $0.tag == "title" })?.textContent ?? ""
        let body = document.first(where: { $0.tag == "body" })
            ?? document.first(where: { $0.tag == "html" })
            ?? document
        resolveNoscriptContent(in: body)
        normalizeImages(in: body)
        removeDiscardedElements(from: body)
        let root = selectContentRoot(in: body)
        let aggressive = extract(from: root.deepCopy(), title: title, baseURL: baseURL, removeClutter: true)
        if wordCount(aggressive) >= 200 { return aggressive }
        let relaxed = extract(from: root.deepCopy(), title: title, baseURL: baseURL, removeClutter: false)
        if wordCount(relaxed) > wordCount(aggressive) * 2 { return relaxed }
        if !aggressive.isEmpty { return aggressive }
        if !relaxed.isEmpty { return relaxed }
        throw DefuddleError.emptyContent
    }

    private static func extract(from root: HTMLNode, title: String, baseURL: URL, removeClutter: Bool) -> String {
        if removeClutter { removeClutterBlocks(from: root) }
        removeMatchingTitle(from: root, title: title)
        removeEmptyBlocks(from: root)
        return MarkdownRenderer(baseURL: baseURL).render(root)
    }

    private static func resolveNoscriptContent(in root: HTMLNode) {
        for noscript in root.elements(where: { $0.tag == "noscript" }).reversed() {
            noscript.unwrap()
        }
    }

    private static func normalizeImages(in root: HTMLNode) {
        for image in root.elements(where: { $0.tag == "img" || $0.tag == "source" }) {
            if image.attribute("src").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                for attribute in ["data-src", "data-original", "data-lazy-src", "data-url"] {
                    let value = image.attribute(attribute).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        image.attributes["src"] = value
                        break
                    }
                }
            }
            if image.attribute("srcset").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                for attribute in ["data-srcset", "data-lazy-srcset"] {
                    let value = image.attribute(attribute).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        image.attributes["srcset"] = value
                        break
                    }
                }
            }
        }
    }

    private static func removeDiscardedElements(from root: HTMLNode) {
        for element in root.elements.reversed() where element !== root {
            let role = element.attribute("role").lowercased()
            let hidden = element.attributes["hidden"] != nil || element.attribute("aria-hidden").lowercased() == "true"
            let style = element.attribute("style").lowercased()
            let inlineHidden = style.range(of: #"(?:display\s*:\s*none|visibility\s*:\s*hidden|opacity\s*:\s*0(?:\D|$))"#, options: .regularExpression) != nil
            let classHidden = !element.classTokens.isDisjoint(with: ["hidden", "invisible"])
            let preservesHiddenContent = element.identity.contains("paywall") || element.identity.contains("math") || element.tag == "svg"
            let discardedRole = ["navigation", "dialog", "alertdialog", "complementary", "banner", "listbox", "option"].contains(role)
            let dismissed = ["dismiss", "close"].contains(element.attribute("aria-label").lowercased())
            if discardedTags.contains(element.tag ?? "") || discardedRole || dismissed || ((hidden || inlineHidden || classHidden) && !preservesHiddenContent) {
                element.remove()
            }
        }
    }

    private static func selectContentRoot(in body: HTMLNode) -> HTMLNode {
        let ranked = body.elements.compactMap { element -> (HTMLNode, Int)? in
            preferredRank(element).map { (element, $0) }
        }.filter { wordCount($0.0.textContent) >= 20 }
        if let firstRank = ranked.map(\.1).min(), let best = bestElement(in: ranked.filter({ $0.1 == firstRank }).map(\.0)) { return best }
        let structural = body.elements.filter { ["article", "main", "section", "div", "td", "blockquote"].contains($0.tag ?? "") }
        if let best = bestElement(in: structural), wordCount(best.textContent) >= 30 { return best }
        return body
    }

    private static func preferredRank(_ element: HTMLNode) -> Int? {
        let id = element.attribute("id").lowercased()
        let classes = element.classTokens
        let role = element.attribute("role").lowercased()
        let selectors: [(Int, Bool)] = [
            (0, id == "post"),
            (1, classes.contains("post-content")),
            (2, classes.contains("post-body")),
            (3, classes.contains("article-content") || id == "article-content"),
            (4, classes.contains("js-article-content")),
            (5, classes.contains("article_post")),
            (6, classes.contains("article-wrapper")),
            (7, classes.contains("entry-content")),
            (8, classes.contains("content-article")),
            (9, classes.contains("instapaper_body")),
            (10, classes.contains("markdown-body")),
            (11, element.tag == "article" || role == "article"),
            (12, element.tag == "main" || role == "main"),
            (13, classes.contains("article-body")),
            (14, id == "main-content"),
            (15, id == "content"),
        ]
        return selectors.first(where: { $0.1 })?.0
    }

    private static func bestElement(in elements: [HTMLNode]) -> HTMLNode? {
        elements.max { contentScore($0) < contentScore($1) }
    }

    private static func contentScore(_ element: HTMLNode) -> Double {
        let text = element.textContent
        let words = wordCount(text)
        guard words > 0 else { return -.infinity }
        let paragraphs = element.elements(where: { $0.tag == "p" }).count
        let commas = text.filter { $0 == "," }.count
        let images = element.elements(where: { $0.tag == "img" }).count
        let linkCharacters = element.elements(where: { $0.tag == "a" }).reduce(0) { $0 + $1.textContent.count }
        let density = min(Double(linkCharacters) / Double(max(text.count, 1)), 0.8)
        var score = Double(words + paragraphs * 10 + commas) - Double(images) / Double(max(words, 1)) * 3
        if positiveTerms.contains(where: element.identity.contains) { score += 35 }
        if negativeTerms.contains(where: element.identity.contains) { score -= 65 }
        if element.tag == "article" { score += 45 }
        if element.tag == "main" { score += 35 }
        if element.tag == "blockquote" { score += 10 }
        let role = element.attribute("role").lowercased()
        if role == "article" || role == "main" { score += 35 }
        return score * (1 - density)
    }

    private static func removeClutterBlocks(from root: HTMLNode) {
        let candidates = root.elements(where: { ["aside", "header", "nav", "footer", "section", "div", "ul", "ol"].contains($0.tag ?? "") }).reversed()
        for block in candidates where block !== root {
            let text = block.textContent
            let words = wordCount(text)
            let paragraphs = block.elements(where: { $0.tag == "p" }).count
            let rich = block.elements.contains { ["pre", "table", "figure", "picture", "math"].contains($0.tag ?? "") }
            let positive = positiveTerms.contains(where: block.identity.contains)
            let negative = negativeTerms.contains(where: block.identity.contains)
            let linkCharacters = block.elements(where: { $0.tag == "a" }).reduce(0) { $0 + $1.textContent.count }
            let linkDensity = Double(linkCharacters) / Double(max(text.count, 1))
            if negative && !positive && words < 120 && paragraphs < 3 && !rich {
                block.remove()
            } else if linkDensity > 0.62 && words < 100 && paragraphs < 6 && !rich {
                block.remove()
            }
        }
        for element in root.elements.reversed() where element !== root {
            let words = wordCount(element.textContent)
            let rich = element.elements.contains { ["pre", "table", "figure", "picture", "math"].contains($0.tag ?? "") }
            if negativeTerms.contains(where: element.identity.contains), words < 40, !rich, element.tag != "p" {
                element.remove()
            }
        }
        removeTrailingHeadings(from: root)
    }

    private static func removeTrailingHeadings(from root: HTMLNode) {
        let headings = root.elements.filter { ["h1", "h2", "h3", "h4", "h5", "h6"].contains($0.tag ?? "") }.reversed()
        for heading in headings where !hasContent(after: heading, within: root) {
            heading.remove()
        }
    }

    private static func hasContent(after node: HTMLNode, within root: HTMLNode) -> Bool {
        var current = node
        while let parent = current.parent {
            if let index = parent.children.firstIndex(where: { $0 === current }) {
                for sibling in parent.children.dropFirst(index + 1) where isMeaningfulContent(sibling) { return true }
            }
            if parent === root { return false }
            current = parent
        }
        return false
    }

    private static func isMeaningfulContent(_ node: HTMLNode) -> Bool {
        guard let tag = node.tag else { return !node.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if ["h1", "h2", "h3", "h4", "h5", "h6"].contains(tag) { return false }
        if ["img", "picture", "video", "audio", "iframe", "table", "pre", "math"].contains(tag) { return true }
        return !node.textContent.isEmpty
    }

    private static func removeMatchingTitle(from root: HTMLNode, title: String) {
        guard !title.isEmpty, let heading = root.first(where: { $0.tag == "h1" }) else { return }
        let pageTitle = normalizedTitle(title)
        let headingTitle = normalizedTitle(heading.textContent)
        if pageTitle == headingTitle { heading.remove() }
    }

    private static func normalizedTitle(_ value: String) -> String {
        value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func removeEmptyBlocks(from root: HTMLNode) {
        let removable = Set(["p", "div", "section", "article", "aside", "header", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "blockquote", "figure"])
        let media = Set(["img", "picture", "video", "audio", "iframe", "svg", "math", "table", "pre", "hr"])
        for element in root.elements.reversed() where element !== root && removable.contains(element.tag ?? "") {
            let text = element.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty && element.elements.allSatisfy({ !media.contains($0.tag ?? "") }) {
                element.remove()
            }
        }
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private final class HTMLNode {
        let tag: String?
        var value: String
        var attributes: [String: String]
        weak var parent: HTMLNode?
        var children: [HTMLNode]

        init(tag: String?, value: String = "", attributes: [String: String] = [:]) {
            self.tag = tag
            self.value = value
            self.attributes = attributes
            children = []
        }

        var elements: [HTMLNode] {
            var result: [HTMLNode] = []
            var stack = Array(children.reversed())
            while let node = stack.popLast() {
                if node.tag != nil { result.append(node) }
                stack.append(contentsOf: node.children.reversed())
            }
            return result
        }

        var textContent: String {
            if tag == nil { return value }
            let separator = HTMLParser.blockTags.contains(tag ?? "") ? " " : ""
            return children.map(\.textContent).joined(separator: separator)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var rawText: String {
            tag == nil ? value : children.map(\.rawText).joined()
        }

        var classTokens: Set<String> {
            Set(attribute("class").lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init))
        }

        var identity: String {
            "\(tag ?? "") \(attribute("id")) \(attribute("class")) \(attribute("role")) \(attribute("data-block")) \(attribute("data-component")) \(attribute("data-testid"))".lowercased()
        }

        func attribute(_ name: String) -> String {
            attributes[name] ?? ""
        }

        func append(_ child: HTMLNode) {
            child.parent = self
            children.append(child)
        }

        func remove() {
            parent?.children.removeAll { $0 === self }
            parent = nil
        }

        func unwrap() {
            guard let parent, let index = parent.children.firstIndex(where: { $0 === self }) else { return }
            parent.children.remove(at: index)
            for child in children { child.parent = parent }
            parent.children.insert(contentsOf: children, at: index)
            children = []
            self.parent = nil
        }

        func first(where predicate: (HTMLNode) -> Bool) -> HTMLNode? {
            if predicate(self) { return self }
            for child in children {
                if let result = child.first(where: predicate) { return result }
            }
            return nil
        }

        func elements(where predicate: (HTMLNode) -> Bool) -> [HTMLNode] {
            elements.filter(predicate)
        }

        func deepCopy() -> HTMLNode {
            let copy = HTMLNode(tag: tag, value: value, attributes: attributes)
            for child in children { copy.append(child.deepCopy()) }
            return copy
        }
    }

    private enum HTMLParser {
        static let blockTags = Set([
            "address", "article", "aside", "blockquote", "dd", "details", "div", "dl", "dt", "fieldset",
            "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header",
            "hr", "li", "main", "nav", "ol", "p", "pre", "section", "summary", "table", "tbody", "td",
            "tfoot", "th", "thead", "tr", "ul",
        ])

        private static let voidTags = Set([
            "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
        ])

        private static let rawTags = Set(["script", "style", "template", "textarea"])

        static func parse(_ html: String) -> HTMLNode {
            let root = HTMLNode(tag: "document")
            var stack = [root]
            var cursor = html.startIndex
            while cursor < html.endIndex {
                guard html[cursor] == "<" else {
                    let end = html[cursor...].firstIndex(of: "<") ?? html.endIndex
                    appendText(String(html[cursor..<end]), to: stack.last!)
                    cursor = end
                    continue
                }
                if html[cursor...].hasPrefix("<!--") {
                    cursor = html.range(of: "-->", range: cursor..<html.endIndex)?.upperBound ?? html.endIndex
                    continue
                }
                let next = html.index(after: cursor)
                if next == html.endIndex || (!isNameCharacter(html[next]) && !["!", "?", "/"].contains(html[next])) {
                    appendText("<", to: stack.last!)
                    cursor = next
                    continue
                }
                guard let tagEnd = findTagEnd(in: html, after: html.index(after: cursor)) else {
                    appendText(String(html[cursor...]), to: stack.last!)
                    break
                }
                let tokenStart = html.index(after: cursor)
                let token = String(html[tokenStart..<tagEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
                cursor = html.index(after: tagEnd)
                if token.isEmpty || token.hasPrefix("!") || token.hasPrefix("?") { continue }
                if token.hasPrefix("/") {
                    let name = token.dropFirst().prefix { isNameCharacter($0) }.lowercased()
                    if let index = stack.lastIndex(where: { $0.tag == name }) {
                        stack.removeSubrange(index..<stack.count)
                    }
                    continue
                }
                let parsed = parseOpeningTag(token)
                guard !parsed.name.isEmpty else { continue }
                closeImpliedElements(for: parsed.name, stack: &stack)
                let node = HTMLNode(tag: parsed.name, attributes: parsed.attributes)
                stack.last!.append(node)
                if !parsed.selfClosing && !voidTags.contains(parsed.name) {
                    stack.append(node)
                    if rawTags.contains(parsed.name) {
                        if let closing = html.range(of: "</\(parsed.name)", options: .caseInsensitive, range: cursor..<html.endIndex) {
                            cursor = closing.lowerBound
                        } else {
                            cursor = html.endIndex
                        }
                    }
                }
            }
            return root
        }

        private static func findTagEnd(in html: String, after start: String.Index) -> String.Index? {
            var cursor = start
            var quote: Character?
            while cursor < html.endIndex {
                let character = html[cursor]
                if let activeQuote = quote {
                    if character == activeQuote { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == ">" {
                    return cursor
                }
                cursor = html.index(after: cursor)
            }
            return nil
        }

        private static func parseOpeningTag(_ token: String) -> (name: String, attributes: [String: String], selfClosing: Bool) {
            let characters = Array(token)
            var index = 0
            func skipWhitespace(_ index: inout Int) {
                while index < characters.count && characters[index].isWhitespace { index += 1 }
            }
            skipWhitespace(&index)
            let nameStart = index
            while index < characters.count && isNameCharacter(characters[index]) { index += 1 }
            let name = String(characters[nameStart..<index]).lowercased()
            var attributes: [String: String] = [:]
            var selfClosing = false
            while index < characters.count {
                skipWhitespace(&index)
                if index >= characters.count { break }
                if characters[index] == "/" {
                    selfClosing = true
                    index += 1
                    continue
                }
                let keyStart = index
                while index < characters.count && !characters[index].isWhitespace && characters[index] != "=" && characters[index] != "/" { index += 1 }
                let key = String(characters[keyStart..<index]).lowercased()
                skipWhitespace(&index)
                var value = ""
                if index < characters.count && characters[index] == "=" {
                    index += 1
                    skipWhitespace(&index)
                    if index < characters.count && (characters[index] == "\"" || characters[index] == "'") {
                        let quote = characters[index]
                        index += 1
                        let valueStart = index
                        while index < characters.count && characters[index] != quote { index += 1 }
                        value = String(characters[valueStart..<index])
                        if index < characters.count { index += 1 }
                    } else {
                        let valueStart = index
                        while index < characters.count && !characters[index].isWhitespace { index += 1 }
                        value = String(characters[valueStart..<index])
                    }
                }
                if !key.isEmpty { attributes[key] = decodeEntities(value) }
            }
            return (name, attributes, selfClosing)
        }

        private static func closeImpliedElements(for name: String, stack: inout [HTMLNode]) {
            if name == "p" || (blockTags.contains(name) && stack.last?.tag == "p") { pop("p", from: &stack) }
            if name == "li" { pop("li", after: ["ul", "ol"], from: &stack) }
            if name == "tr" { pop("tr", after: ["table", "thead", "tbody", "tfoot"], from: &stack) }
            if name == "td" || name == "th" {
                pop("td", after: ["tr"], from: &stack)
                pop("th", after: ["tr"], from: &stack)
            }
            if name.first == "h", name.count == 2, name.last?.isNumber == true,
               let current = stack.last?.tag, current.first == "h", current.count == 2 {
                stack.removeLast()
            }
        }

        private static func pop(_ tag: String, from stack: inout [HTMLNode]) {
            guard let index = stack.lastIndex(where: { $0.tag == tag }) else { return }
            stack.removeSubrange(index..<stack.count)
        }

        private static func pop(_ tag: String, after boundaries: Set<String>, from stack: inout [HTMLNode]) {
            let boundary = stack.lastIndex(where: { boundaries.contains($0.tag ?? "") }) ?? 0
            guard let index = stack.lastIndex(where: { $0.tag == tag }), index > boundary else { return }
            stack.removeSubrange(index..<stack.count)
        }

        private static func appendText(_ text: String, to parent: HTMLNode) {
            guard !text.isEmpty else { return }
            parent.append(HTMLNode(tag: nil, value: decodeEntities(text)))
        }

        private static func isNameCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "-" || character == "_" || character == ":"
        }

        private static func decodeEntities(_ value: String) -> String {
            guard value.contains("&") else { return value }
            let named = [
                "amp": "&", "apos": "'", "bull": "•", "cent": "¢", "copy": "©", "divide": "÷",
                "emsp": " ", "ensp": " ", "euro": "€", "gt": ">", "hellip": "…", "laquo": "«",
                "ldquo": "“", "lsquo": "‘", "lt": "<", "mdash": "—", "middot": "·", "nbsp": " ",
                "ndash": "–", "pound": "£", "quot": "\"", "raquo": "»", "rdquo": "”", "reg": "®",
                "rsquo": "’", "times": "×", "trade": "™", "yen": "¥",
            ]
            var result = ""
            var cursor = value.startIndex
            while cursor < value.endIndex {
                guard value[cursor] == "&",
                      let semicolon = value[cursor...].firstIndex(of: ";"),
                      value.distance(from: cursor, to: semicolon) <= 12 else {
                    result.append(value[cursor])
                    cursor = value.index(after: cursor)
                    continue
                }
                let entityStart = value.index(after: cursor)
                let entity = String(value[entityStart..<semicolon])
                let replacement: String?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init).map(String.init)
                } else if entity.hasPrefix("#") {
                    replacement = UInt32(entity.dropFirst()).flatMap(UnicodeScalar.init).map(String.init)
                } else {
                    replacement = named[entity.lowercased()]
                }
                if let replacement {
                    result += replacement
                    cursor = value.index(after: semicolon)
                } else {
                    result.append(value[cursor])
                    cursor = value.index(after: cursor)
                }
            }
            return result
        }
    }

    private struct MarkdownRenderer {
        let baseURL: URL

        func render(_ root: HTMLNode) -> String {
            normalize(renderChildren(root, listDepth: 0))
        }

        private func renderNode(_ node: HTMLNode, listDepth: Int) -> String {
            guard let tag = node.tag else { return renderText(node) }
            switch tag {
            case "script", "style", "noscript", "template", "meta", "link", "base", "source", "track": return ""
            case "br": return "  \n"
            case "hr": return "\n\n---\n\n"
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let level = max(2, Int(tag.dropFirst()) ?? 1)
                let content = compactInline(renderChildren(node, listDepth: listDepth))
                return content.isEmpty ? "" : "\n\n\(String(repeating: "#", count: level)) \(content)\n\n"
            case "p", "article", "main", "section", "div", "header", "footer", "address", "figcaption": return block(renderChildren(node, listDepth: listDepth))
            case "strong", "b": return wrapInline(renderChildren(node, listDepth: listDepth), marker: "**")
            case "em", "i": return wrapInline(renderChildren(node, listDepth: listDepth), marker: "*")
            case "del", "s", "strike": return wrapInline(renderChildren(node, listDepth: listDepth), marker: "~~")
            case "code": return node.parent?.tag == "pre" ? node.rawText : inlineCode(node.rawText)
            case "pre": return codeBlock(node)
            case "a": return link(node, listDepth: listDepth)
            case "img": return image(node)
            case "picture": return picture(node)
            case "ul", "ol": return list(node, depth: listDepth)
            case "li": return renderChildren(node, listDepth: listDepth)
            case "blockquote": return quote(node, listDepth: listDepth)
            case "table": return table(node)
            case "thead", "tbody", "tfoot", "tr", "td", "th": return renderChildren(node, listDepth: listDepth)
            case "dl": return block(renderChildren(node, listDepth: listDepth))
            case "dt":
                let content = compactInline(renderChildren(node, listDepth: listDepth))
                return content.isEmpty ? "" : "\n\n**\(content)**\n"
            case "dd": return block(renderChildren(node, listDepth: listDepth))
            case "sup", "sub":
                let content = compactInline(renderChildren(node, listDepth: listDepth))
                return content.isEmpty ? "" : "<\(tag)>\(content)</\(tag)>"
            case "iframe", "video", "audio": return mediaLink(node)
            case "math": return math(node)
            case "input": return ""
            default: return renderChildren(node, listDepth: listDepth)
            }
        }

        private func renderChildren(_ node: HTMLNode, listDepth: Int) -> String {
            node.children.map { renderNode($0, listDepth: listDepth) }.joined()
        }

        private func renderText(_ node: HTMLNode) -> String {
            if node.value.allSatisfy({ $0.isWhitespace }), let parent = node.parent,
               let index = parent.children.firstIndex(where: { $0 === node }) {
                let previousIsBlock = index > 0 && HTMLParser.blockTags.contains(parent.children[index - 1].tag ?? "")
                let nextIsBlock = index + 1 < parent.children.count && HTMLParser.blockTags.contains(parent.children[index + 1].tag ?? "")
                if previousIsBlock || nextIsBlock { return "" }
            }
            return escapeText(normalizeInlineWhitespace(node.value))
        }

        private func block(_ content: String) -> String {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "" : "\n\n\(trimmed)\n\n"
        }

        private func wrapInline(_ content: String, marker: String) -> String {
            let leading = String(content.prefix(while: { $0.isWhitespace }))
            let trailing = String(content.reversed().prefix(while: { $0.isWhitespace }).reversed())
            let core = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return core.isEmpty ? content : "\(leading)\(marker)\(core)\(marker)\(trailing)"
        }

        private func link(_ node: HTMLNode, listDepth: Int) -> String {
            let content = compactInline(renderChildren(node, listDepth: listDepth))
            guard let destination = safeURL(node.attribute("href"), image: false) else { return content }
            let label = content.isEmpty ? escapeText(destination) : content
            let title = node.attribute("title").trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = title.isEmpty ? "" : " \"\(title.replacingOccurrences(of: "\"", with: "\\\""))\""
            return "[\(label)](\(markdownDestination(destination))\(suffix))"
        }

        private func image(_ node: HTMLNode) -> String {
            guard let destination = bestImageURL(node) else {
                return escapeText(node.attribute("alt").trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return markdownImage(node, destination: destination)
        }

        private func picture(_ node: HTMLNode) -> String {
            guard let image = node.elements.first(where: { $0.tag == "img" }) else { return "" }
            if let destination = bestImageURL(image) { return markdownImage(image, destination: destination) }
            for source in node.elements where source.tag == "source" {
                if let destination = bestImageURL(source) { return markdownImage(image, destination: destination) }
            }
            return ""
        }

        private func markdownImage(_ node: HTMLNode, destination: String) -> String {
            let alt = escapeText(node.attribute("alt").trimmingCharacters(in: .whitespacesAndNewlines))
            let title = node.attribute("title").trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = title.isEmpty ? "" : " \"\(title.replacingOccurrences(of: "\"", with: "\\\""))\""
            return "![\(alt)](\(markdownDestination(destination))\(suffix))"
        }

        private func bestImageURL(_ node: HTMLNode) -> String? {
            var candidates: [(String, Double)] = []
            for entry in node.attribute("srcset").split(separator: ",") {
                let parts = entry.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0.isWhitespace })
                guard let first = parts.first else { continue }
                let descriptor = parts.dropFirst().first.map(String.init) ?? "1x"
                let weight: Double
                if descriptor.hasSuffix("w") { weight = Double(descriptor.dropLast()) ?? 0 }
                else if descriptor.hasSuffix("x") { weight = (Double(descriptor.dropLast()) ?? 1) * 1_000 }
                else { weight = 1 }
                candidates.append((String(first), weight))
            }
            if let source = candidates.max(by: { $0.1 < $1.1 })?.0, let resolved = safeURL(source, image: true) { return resolved }
            return safeURL(node.attribute("src"), image: true)
        }

        private func list(_ node: HTMLNode, depth: Int) -> String {
            let ordered = node.tag == "ol"
            let start = Int(node.attribute("start")) ?? 1
            let items = node.children.filter { $0.tag == "li" }
            var lines: [String] = []
            for (index, item) in items.enumerated() {
                var primary = ""
                var nested = ""
                for child in item.children {
                    if child.tag == "ul" || child.tag == "ol" { nested += list(child, depth: depth + 1) }
                    else { primary += renderNode(child, listDepth: depth) }
                }
                let checkbox = item.elements.first { $0.tag == "input" && $0.attribute("type").lowercased() == "checkbox" }
                let task = checkbox.map { $0.attributes["checked"] != nil ? "[x] " : "[ ] " } ?? ""
                let marker = ordered ? "\(start + index). " : "- "
                let indent = String(repeating: "  ", count: depth)
                let continuation = indent + String(repeating: " ", count: marker.count)
                let content = compactBlock(primary).split(separator: "\n", omittingEmptySubsequences: false).enumerated().map {
                    $0.offset == 0 ? String($0.element) : continuation + $0.element
                }.joined(separator: "\n")
                lines.append("\(indent)\(marker)\(task)\(content)\(nested)")
            }
            return lines.isEmpty ? "" : "\n\(lines.joined(separator: "\n"))\n"
        }

        private func quote(_ node: HTMLNode, listDepth: Int) -> String {
            let content = normalize(renderChildren(node, listDepth: listDepth))
            guard !content.isEmpty else { return "" }
            return "\n\n" + content.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n") + "\n\n"
        }

        private func codeBlock(_ node: HTMLNode) -> String {
            let content = node.rawText.trimmingCharacters(in: .newlines)
            guard !content.isEmpty else { return "" }
            let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: content) + 1))
            let code = node.children.first(where: { $0.tag == "code" })
            let classes = code?.attribute("class") ?? ""
            let language = classes.split(whereSeparator: { $0.isWhitespace }).compactMap { token -> String? in
                for prefix in ["language-", "lang-"] where token.hasPrefix(prefix) { return String(token.dropFirst(prefix.count)) }
                return nil
            }.first ?? ""
            return "\n\n\(fence)\(language)\n\(content)\n\(fence)\n\n"
        }

        private func inlineCode(_ content: String) -> String {
            guard !content.isEmpty else { return "" }
            let fence = String(repeating: "`", count: max(1, longestBacktickRun(in: content) + 1))
            let padding = content.hasPrefix("`") || content.hasSuffix("`") || content.hasPrefix(" ") || content.hasSuffix(" ") ? " " : ""
            return "\(fence)\(padding)\(content)\(padding)\(fence)"
        }

        private func table(_ node: HTMLNode) -> String {
            let rows = node.elements.filter { row in
                guard row.tag == "tr" else { return false }
                var parent = row.parent
                while let current = parent {
                    if current.tag == "table" { return current === node }
                    parent = current.parent
                }
                return false
            }
            let rendered = rows.map { row in
                row.children.filter { $0.tag == "td" || $0.tag == "th" }.map { cell in
                    compactBlock(renderChildren(cell, listDepth: 0)).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "\\|")
                }
            }.filter { !$0.isEmpty }
            guard let width = rendered.map(\.count).max(), width > 0 else { return "" }
            func row(_ cells: [String]) -> String {
                "| " + (cells + Array(repeating: "", count: width - cells.count)).joined(separator: " | ") + " |"
            }
            let separator = "| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |"
            return "\n\n" + ([row(rendered[0]), separator] + rendered.dropFirst().map(row)).joined(separator: "\n") + "\n\n"
        }

        private func mediaLink(_ node: HTMLNode) -> String {
            guard let source = safeURL(node.attribute("src"), image: false) else { return renderChildren(node, listDepth: 0) }
            return "\n\n[Embedded media](\(markdownDestination(source)))\n\n"
        }

        private func math(_ node: HTMLNode) -> String {
            for attribute in ["data-latex", "alttext", "alt"] {
                let value = node.attribute(attribute).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return "$\(value)$" }
            }
            let content = node.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            return content.isEmpty ? "" : "$\(content)$"
        }

        private func safeURL(_ value: String, image: Bool) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasPrefix("#") { return trimmed }
            guard let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
                  let scheme = resolved.scheme?.lowercased() else { return nil }
            let allowed = image ? ["http", "https"] : ["http", "https", "mailto", "tel"]
            return allowed.contains(scheme) ? resolved.absoluteString : nil
        }

        private func markdownDestination(_ value: String) -> String {
            if value.contains(where: { $0.isWhitespace }) { return "<\(value.replacingOccurrences(of: ">", with: "\\>"))>" }
            return value.replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")
        }

        private func normalizeInlineWhitespace(_ value: String) -> String {
            value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }

        private func compactInline(_ value: String) -> String {
            normalizeInlineWhitespace(value).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func compactBlock(_ value: String) -> String {
            value.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
                .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func normalize(_ value: String) -> String {
            compactBlock(value)
        }

        private func escapeText(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "*", with: "\\*")
                .replacingOccurrences(of: "_", with: "\\_")
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
                .replacingOccurrences(of: "<(?=/?[A-Za-z][A-Za-z0-9-]*(?:\\s|/?>))", with: "\\\\<", options: .regularExpression)
        }

        private func longestBacktickRun(in value: String) -> Int {
            var longest = 0
            var current = 0
            for character in value {
                if character == "`" {
                    current += 1
                    longest = max(longest, current)
                } else {
                    current = 0
                }
            }
            return longest
        }
    }
}
