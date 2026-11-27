import Foundation

nonisolated enum MarkdownListKind: Equatable, Sendable {
    case bullets
    case ordered
}

nonisolated struct MarkdownListItem: Equatable, Sendable {
    let text: String
    let children: [MarkdownList]
}

nonisolated struct MarkdownList: Equatable, Sendable {
    let kind: MarkdownListKind
    let items: [MarkdownListItem]
}

nonisolated enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(Int, String)
    case lists([MarkdownList])
    case code(language: String?, body: String)
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule
    case embed(alt: String, path: String)

    var logShape: String {
        switch self {
        case .paragraph(let text): return "paragraph(chars:\(text.count))"
        case .heading(let level, let text): return "heading(level:\(level),chars:\(text.count))"
        case .lists(let lists): return "lists(groups:\(lists.count),items:\(lists.itemCount),chars:\(lists.characterCount))"
        case .code(let language, let body): return "code(language:\(language ?? "none"),chars:\(body.count))"
        case .quote(let text): return "quote(chars:\(text.count))"
        case .table(let header, let rows): return "table(columns:\(header.count),rows:\(rows.count))"
        case .rule: return "rule"
        case .embed: return "embed"
        }
    }

    static func parse(_ source: String) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { i += 1; continue }

            if trimmed.hasPrefix("```") {
                let languageHint = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let language = languageHint.isEmpty ? nil : languageHint
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i]); i += 1
                }
                if i < lines.count { i += 1 }
                out.append(.code(language: language, body: body.joined(separator: "\n")))
                continue
            }

            if let embed = embed(trimmed) {
                out.append(embed); i += 1; continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                out.append(.rule); i += 1; continue
            }

            if trimmed.hasPrefix("#") {
                var level = 0
                for ch in trimmed { if ch == "#" { level += 1 } else { break } }
                if level <= 6, trimmed.count > level, trimmed[trimmed.index(trimmed.startIndex, offsetBy: level)] == " " {
                    out.append(.heading(level, String(trimmed.dropFirst(level + 1))))
                    i += 1; continue
                }
            }

            if trimmed.hasPrefix("> ") {
                var quoted: [String] = [String(trimmed.dropFirst(2))]
                i += 1
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("> ") {
                    quoted.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst(2)))
                    i += 1
                }
                out.append(.quote(quoted.joined(separator: " ")))
                continue
            }

            if listLine(line) != nil {
                var listLines: [MarkdownListLine] = []
                while i < lines.count, let listLine = listLine(lines[i]) {
                    listLines.append(listLine)
                    i += 1
                }
                var listIndex = 0
                out.append(.lists(parseLists(
                    listLines,
                    index: &listIndex,
                    indentation: listLines[0].indentation
                )))
                continue
            }

            if isTableStart(at: i, in: lines) {
                let header = splitRow(trimmed)
                i += 2
                var rows: [[String]] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty || !t.contains("|") { break }
                    rows.append(normalizeRow(splitRow(t), width: header.count))
                    i += 1
                }
                out.append(.table(header: header, rows: rows))
                continue
            }

            var para: [String] = [trimmed]
            i += 1
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") || t.hasPrefix("```") || t.hasPrefix("> ")
                    || isBullet(t) || isOrdered(t) || t == "---" || isTableStart(at: i, in: lines) { break }
                para.append(t); i += 1
            }
            out.append(.paragraph(para.joined(separator: " ")))
        }
        return out
    }

    static func embed(_ line: String) -> MarkdownBlock? {
        guard let match = line.wholeMatch(of: /!\[([^\]]*)\]\(<?([^)>]+)>?\)/) else { return nil }
        let path = String(match.2).trimmingCharacters(in: .whitespaces)
        if path.contains(":") {
            guard let url = URLComponents(string: path), url.scheme == "https", url.host?.isEmpty == false,
                  url.user == nil, url.password == nil else { return nil }
            return .embed(alt: String(match.1), path: path)
        }
        return .embed(alt: String(match.1), path: path.removingPercentEncoding ?? path)
    }

    private static func isTableStart(at i: Int, in lines: [String]) -> Bool {
        guard i + 1 < lines.count else { return false }
        let header = lines[i].trimmingCharacters(in: .whitespaces)
        let separator = lines[i + 1].trimmingCharacters(in: .whitespaces)
        return header.contains("|") && isTableSeparator(separator)
    }

    static func isTableSeparator(_ s: String) -> Bool {
        guard s.contains("|"), s.contains("-") else { return false }
        let cells = splitRow(s)
        return !cells.isEmpty && cells.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func splitRow(_ s: String) -> [String] {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func normalizeRow(_ cells: [String], width: Int) -> [String] {
        if cells.count >= width { return Array(cells.prefix(width)) }
        return cells + Array(repeating: "", count: width - cells.count)
    }

    private static let emphasisWraps = ["**", "__", "*", "_"]

    private struct MarkdownListLine {
        let indentation: Int
        let kind: MarkdownListKind
        let body: String
    }

    private static func listLine(_ line: String) -> MarkdownListLine? {
        let indentation = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { width, character in
            width + (character == "\t" ? 4 : 1)
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let body = bulletBody(trimmed) {
            return MarkdownListLine(indentation: indentation, kind: .bullets, body: body)
        }
        if let body = orderedBody(trimmed) {
            return MarkdownListLine(indentation: indentation, kind: .ordered, body: body)
        }
        return nil
    }

    private static func parseLists(
        _ lines: [MarkdownListLine],
        index: inout Int,
        indentation: Int
    ) -> [MarkdownList] {
        var lists: [MarkdownList] = []
        while index < lines.count, lines[index].indentation == indentation {
            let kind = lines[index].kind
            var items: [MarkdownListItem] = []
            while index < lines.count,
                  lines[index].indentation == indentation,
                  lines[index].kind == kind {
                let line = lines[index]
                index += 1
                var children: [MarkdownList] = []
                while index < lines.count, lines[index].indentation > indentation {
                    children += parseLists(lines, index: &index, indentation: lines[index].indentation)
                }
                items.append(MarkdownListItem(text: line.body, children: children))
            }
            lists.append(MarkdownList(kind: kind, items: items))
        }
        return lists
    }

    private static func isBullet(_ s: String) -> Bool { bulletBody(s) != nil }

    private static func bulletBody(_ s: String) -> String? {
        if let body = plainBulletBody(Substring(s)) { return body }
        for wrap in emphasisWraps {
            if let body = wrappedBulletBody(Substring(s), wrap: wrap) { return body }
        }
        return nil
    }

    private static func plainBulletBody(_ s: Substring) -> String? {
        var t = s
        guard let marker = t.first, marker == "-" || marker == "*" || marker == "+" else { return nil }
        t = t.dropFirst()
        guard t.first == " " else { return nil }
        return String(t.dropFirst())
    }

    private static func wrappedBulletBody(_ s: Substring, wrap: String) -> String? {
        var t = s
        guard t.hasPrefix(wrap) else { return nil }
        t = t.dropFirst(wrap.count)
        guard let marker = t.first, marker == "-" || marker == "*" || marker == "+" else { return nil }
        t = t.dropFirst()
        guard t.hasPrefix(wrap) else { return nil }
        t = t.dropFirst(wrap.count)
        guard t.first == " " else { return nil }
        return String(t.dropFirst())
    }

    private static func isOrdered(_ s: String) -> Bool { orderedBody(s) != nil }

    private static func orderedBody(_ s: String) -> String? {
        var t = Substring(s)
        let wrap = emphasisWraps.first { t.hasPrefix($0) } ?? ""
        t = t.dropFirst(wrap.count)
        let digits = t.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        t = t.dropFirst(digits.count)
        guard t.first == "." else { return nil }
        t = t.dropFirst()
        guard t.hasPrefix(wrap) else { return nil }
        t = t.dropFirst(wrap.count)
        guard t.first == " " else { return nil }
        return String(t.dropFirst())
    }
}

nonisolated extension Array where Element == MarkdownList {
    var itemCount: Int {
        reduce(0) { count, list in
            count + list.items.reduce(0) { $0 + 1 + $1.children.itemCount }
        }
    }

    var characterCount: Int {
        reduce(0) { count, list in
            count + list.items.reduce(0) { $0 + $1.text.count + $1.children.characterCount }
        }
    }

    var utf8Count: Int {
        reduce(0) { count, list in
            count + list.items.reduce(0) { $0 + $1.text.utf8.count + $1.children.utf8Count }
        }
    }
}

nonisolated extension MarkdownBlock {
    static func plainText(_ source: String) -> String {
        parse(source).flatMap(\.plainLines).joined(separator: "\n")
    }

    private var plainLines: [String] {
        switch self {
        case .paragraph(let text), .heading(_, let text), .quote(let text): return [Self.plainInline(text)]
        case .lists(let lists): return lists.flatMap(Self.plainLines)
        case .code(_, let body): return body.isEmpty ? [] : [body]
        case .table(let header, let rows): return ([header] + rows).map { $0.map(Self.plainInline).joined(separator: ", ") }
        case .rule: return []
        case .embed(let alt, _): return alt.isEmpty ? [] : [Self.plainInline(alt)]
        }
    }

    private static func plainLines(_ list: MarkdownList) -> [String] {
        list.items.enumerated().flatMap { index, item in
            let marker = list.kind == .ordered ? "\(index + 1). " : ""
            return [marker + plainInline(item.text)] + item.children.flatMap(plainLines)
        }
    }

    private static func plainInline(_ text: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let attributed = try? AttributedString(markdown: text, options: options) else { return text }
        return String(attributed.characters)
    }
}
