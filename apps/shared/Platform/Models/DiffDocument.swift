import Foundation

nonisolated struct DiffDocument: Sendable {
    enum Kind: Sendable {
        case context, addition, deletion, metadata, hunk
    }

    struct Line: Sendable {
        let kind: Kind
        let range: NSRange
        let oldNumber: Int?
        let newNumber: Int?
    }

    private struct Cursor {
        var oldNumber: Int
        var newNumber: Int
        var oldRemaining: Int
        var newRemaining: Int

        init?(_ text: String) {
            guard let match = text.firstMatch(of: /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/),
                  let old = Int(match.1), let new = Int(match.3),
                  let oldCount = Int(match.2.map(String.init) ?? "1"),
                  let newCount = Int(match.4.map(String.init) ?? "1") else { return nil }
            oldNumber = old
            newNumber = new
            oldRemaining = oldCount
            newRemaining = newCount
            guard old <= Int.max - oldRemaining, new <= Int.max - newRemaining else { return nil }
        }

        mutating func consume(_ kind: Kind) -> (Int?, Int?)? {
            switch kind {
            case .addition where newRemaining > 0:
                defer { newNumber += 1; newRemaining -= 1 }
                return (nil, newNumber)
            case .deletion where oldRemaining > 0:
                defer { oldNumber += 1; oldRemaining -= 1 }
                return (oldNumber, nil)
            case .context where oldRemaining > 0 && newRemaining > 0:
                defer { oldNumber += 1; newNumber += 1; oldRemaining -= 1; newRemaining -= 1 }
                return (oldNumber, newNumber)
            default:
                return nil
            }
        }
    }

    struct CodeLine: Sendable {
        let text: String
        let kind: Kind
        let oldNumber: Int?
        let newNumber: Int?
    }

    struct Hunk: Identifiable, Sendable {
        let id: Int
        var lines: [CodeLine] = []
    }

    struct File: Identifiable, Sendable {
        enum Change: Sendable {
            case modified, added, deleted, renamed, binary
        }

        let id: Int
        var oldPath: String?
        var newPath: String?
        var change: Change = .modified
        var hunks: [Hunk] = []
        var path: String? { newPath ?? oldPath }
        var additions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .addition } } }
        var deletions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .deletion } } }
    }

    private struct FileBuilder {
        enum Phase {
            case headers, oldHeader, newHeader, content
        }

        var file: File
        var phase: Phase = .headers
    }

    let lines: [Line]
    let files: [File]
    let codeLines: [CodeLine]
    var additions: Int { lines.count { $0.kind == .addition } }
    var deletions: Int { lines.count { $0.kind == .deletion } }

    static func supports(_ language: String?) -> Bool {
        ["diff", "patch"].contains(language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")
    }

    init(_ source: String) {
        var offset = 0
        var hunk: Cursor?
        lines = source.components(separatedBy: "\n").map { text in
            let range = NSRange(location: offset, length: text.utf16.count)
            offset += range.length + 1
            let kind: Kind
            var numbers: (Int?, Int?) = (nil, nil)
            if text.hasPrefix("@@") {
                kind = .hunk
                hunk = Cursor(text)
            } else if text.hasPrefix("\\") {
                kind = .metadata
            } else {
                let candidate: Kind = text.hasPrefix("+") ? .addition : text.hasPrefix("-") ? .deletion : .context
                if let consumed = hunk?.consume(candidate), text.first == " " || candidate != .context {
                    kind = candidate
                    numbers = consumed
                } else {
                    hunk = nil
                    if Self.isMetadata(text) {
                        kind = .metadata
                    } else {
                        kind = candidate
                    }
                }
            }
            return Line(kind: kind, range: range, oldNumber: numbers.0, newNumber: numbers.1)
        }
        let ns = source as NSString
        codeLines = lines.compactMap { Self.codeLine($0, text: ns.substring(with: $0.range)) }
        files = Self.parseFiles(lines, source: ns)
    }

    private static func isMetadata(_ text: String) -> Bool {
        ["diff ", "index ", "--- ", "+++ ", "new file mode ", "deleted file mode ",
         "old mode ", "new mode ", "similarity index ", "dissimilarity index ",
         "rename from ", "rename to ", "copy from ", "copy to ", "Binary files ",
         "GIT binary patch", "literal ", "delta "].contains { text.hasPrefix($0) }
    }

    private static func codeLine(_ line: Line, text: String) -> CodeLine? {
        guard line.kind == .context || line.kind == .addition || line.kind == .deletion else { return nil }
        let content = text.first == " " || line.kind != .context ? String(text.dropFirst()) : text
        return CodeLine(text: content, kind: line.kind, oldNumber: line.oldNumber, newNumber: line.newNumber)
    }

    private static func parseFiles(_ lines: [Line], source: NSString) -> [File] {
        var files: [File] = []
        var builder: FileBuilder?
        for line in lines {
            let text = source.substring(with: line.range)
            if text.hasPrefix("diff --git ") {
                if let builder { files.append(builder.file) }
                let paths = String(text.dropFirst(11))
                let boundary = paths.range(of: " b/") ?? paths.range(of: " \"b/")
                builder = FileBuilder(file: File(id: line.range.location,
                    oldPath: path(boundary.map { String(paths[..<$0.lowerBound]) } ?? paths),
                    newPath: boundary.map { path(String(paths[$0.lowerBound...].dropFirst())) } ?? nil))
            } else if line.kind == .metadata, text.hasPrefix("--- ") {
                if builder?.phase != .headers {
                    if let builder { files.append(builder.file) }
                    builder = FileBuilder(file: File(id: line.range.location))
                }
                builder?.file.oldPath = path(String(text.dropFirst(4)))
                if builder?.file.oldPath == nil { builder?.file.change = .added }
                builder?.phase = .oldHeader
            } else if line.kind == .metadata, text.hasPrefix("+++ ") {
                if builder == nil { builder = FileBuilder(file: File(id: line.range.location)) }
                builder?.file.newPath = path(String(text.dropFirst(4)))
                if builder?.file.newPath == nil { builder?.file.change = .deleted }
                builder?.phase = .newHeader
            } else if text.hasPrefix("rename from ") {
                builder?.file.oldPath = path(String(text.dropFirst(12)), stripPrefix: false)
                builder?.file.change = .renamed
            } else if text.hasPrefix("rename to ") {
                builder?.file.newPath = path(String(text.dropFirst(10)), stripPrefix: false)
                builder?.file.change = .renamed
            } else if text.hasPrefix("new file mode ") {
                builder?.file.change = .added
            } else if text.hasPrefix("deleted file mode ") {
                builder?.file.change = .deleted
            } else if text.hasPrefix("Binary files ") || text == "GIT binary patch" {
                builder?.file.change = .binary
            } else if line.kind == .hunk {
                builder?.file.hunks.append(Hunk(id: line.range.location))
                builder?.phase = .content
            } else if let content = codeLine(line, text: text), !text.isEmpty, builder != nil, builder?.file.change != .binary {
                if builder?.file.hunks.isEmpty == true {
                    builder?.file.hunks.append(Hunk(id: line.range.location))
                }
                if let index = builder?.file.hunks.indices.last {
                    builder?.file.hunks[index].lines.append(content)
                }
                builder?.phase = .content
            }
        }
        if let builder { files.append(builder.file) }
        return files
    }

    private static func path(_ raw: String, stripPrefix: Bool = true) -> String? {
        let value = String(raw.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)[0])
            .trimmingCharacters(in: .newlines)
        let decoded = unquote(value)
        guard decoded != "/dev/null", !decoded.isEmpty else { return nil }
        if stripPrefix, decoded.hasPrefix("a/") || decoded.hasPrefix("b/") {
            return String(decoded.dropFirst(2))
        }
        return decoded
    }

    private static func unquote(_ value: String) -> String {
        guard value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        let input = Array(value.dropFirst().dropLast().utf8)
        var output: [UInt8] = []
        var index = 0
        let escapes: [UInt8: UInt8] = [97: 7, 98: 8, 116: 9, 110: 10, 118: 11, 102: 12, 114: 13]
        while index < input.count {
            let byte = input[index]
            index += 1
            guard byte == 92, index < input.count else {
                output.append(byte)
                continue
            }
            if (48...55).contains(input[index]) {
                var octal = 0
                var digits = 0
                while index < input.count, digits < 3, (48...55).contains(input[index]) {
                    octal = octal * 8 + Int(input[index] - 48)
                    index += 1
                    digits += 1
                }
                guard let decoded = UInt8(exactly: octal) else { return value }
                output.append(decoded)
            } else {
                output.append(escapes[input[index]] ?? input[index])
                index += 1
            }
        }
        return String(decoding: output, as: UTF8.self)
    }
}
