import Foundation
import PDFKit

nonisolated enum FileLibrary {
    struct ListOptions {
        var query = ""
        var limit = 50
    }

    struct ReadOptions {
        var maxBytes: Int?
        var maxPages: Int?
    }

    struct Item: Encodable, Sendable {
        let filename: String
        let type: String
        let mimeType: String
        let kind: String
        let size: Int?
        let createdAt: String?
        let modifiedAt: String?
        let exists: Bool

        init(_ file: FileItem) {
            filename = file.fileName
            type = file.typeIdentifier
            mimeType = file.mimeType
            kind = file.kind.rawValue
            size = file.size
            createdAt = file.createdAt?.ISO8601Format()
            modifiedAt = file.modifiedAt?.ISO8601Format()
            exists = file.exists
        }
    }

    struct Listing: Encodable, Sendable {
        let items: [Item]
        let truncated: Bool
    }

    struct Read: Encodable, Sendable {
        let text: String?
        let truncated: Bool
        let unsupported: String?

        private enum CodingKeys: String, CodingKey {
            case text, truncated, unsupported
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(text, forKey: .text)
            try container.encode(truncated, forKey: .truncated)
            try container.encode(unsupported, forKey: .unsupported)
        }
    }

    static func list(_ files: [FileItem], options: ListOptions) -> Listing {
        let matching = files
            .filter { options.query.isEmpty || $0.fileName.localizedCaseInsensitiveContains(options.query) }
            .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        let limit = clamp(options.limit, min: 1, max: 100)
        return Listing(items: matching.prefix(limit).map(Item.init), truncated: matching.count > limit)
    }

    static func read(_ file: FileItem, options: ReadOptions) throws -> Read {
        guard file.exists else {
            return Read(text: nil, truncated: false, unsupported: "Missing file.")
        }
        if let size = file.size, size > FileLimits.fileBytes {
            throw FileError.fileTooLarge(bytes: size, limit: FileLimits.fileBytes)
        }
        return try read(
            data: Data(contentsOf: file.fileURL),
            kind: file.kind,
            options: options
        )
    }

    static func read(data: Data, kind: FileItem.Kind, options: ReadOptions) throws -> Read {
        guard data.count <= FileLimits.fileBytes else {
            throw FileError.fileTooLarge(bytes: data.count, limit: FileLimits.fileBytes)
        }
        let maxBytes = options.maxBytes.map { clamp($0, min: 1, max: FileLimits.fileBytes) } ?? FileLimits.fileBytes
        switch kind {
        case .text, .html:
            guard let fullText = String(data: data, encoding: .utf8) else { throw FileError.textNotUTF8 }
            let truncated = data.count > maxBytes
            guard truncated else { return Read(text: fullText, truncated: false, unsupported: nil) }
            var end = data.index(data.startIndex, offsetBy: min(maxBytes, data.count))
            while end != data.endIndex && data[end] & 0xC0 == 0x80 {
                end = data.index(before: end)
            }
            guard let text = String(data: data[..<end], encoding: .utf8) else { throw FileError.textNotUTF8 }
            return Read(text: text, truncated: truncated, unsupported: nil)
        case .pdf:
            guard let document = PDFDocument(data: data) else {
                return Read(text: nil, truncated: false, unsupported: "The PDF couldn't be read.")
            }
            let pageLimit = options.maxPages.map { min(document.pageCount, max(1, $0)) } ?? document.pageCount
            var text = ""
            let truncated = pageLimit < document.pageCount
            for index in 0..<pageLimit {
                guard let pageText = document.page(at: index)?.string else { continue }
                let section = "Page \(index + 1)\n\(pageText)"
                let candidate = text.isEmpty ? section : text + "\n\n" + section
                if candidate.utf8.count > maxBytes {
                    guard options.maxBytes != nil else {
                        throw FileError.textTooLarge(bytes: candidate.utf8.count, limit: FileLimits.fileBytes)
                    }
                    return try read(data: Data(candidate.utf8), kind: .text, options: options)
                }
                text = candidate
            }
            return Read(text: text, truncated: truncated, unsupported: nil)
        case .image:
            return Read(text: nil, truncated: false, unsupported: ModelGuidance.text("image.fileRead"))
        case .file:
            return Read(text: nil, truncated: false, unsupported: ModelGuidance.text("file.conversion"))
        }
    }

    static func listOptions(from value: JSONValue?) -> ListOptions {
        let values = value?.objectValue ?? [:]
        return ListOptions(query: values["query"]?.stringValue ?? "", limit: int(values["limit"], default: 50))
    }

    static func readOptions(from value: JSONValue?) -> ReadOptions {
        let values = value?.objectValue ?? [:]
        return ReadOptions(
            maxBytes: values["maxBytes"].map { int($0, default: FileLimits.fileBytes) },
            maxPages: values["maxPages"].map { int($0, default: Int.max) }
        )
    }

    private static func int(_ candidate: JSONValue?, default value: Int) -> Int {
        if let integer = candidate?.intValue { return integer }
        if let string = candidate?.stringValue, let integer = Int(string) { return integer }
        return value
    }

    private static func clamp(_ value: Int, min: Int, max: Int) -> Int {
        Swift.max(min, Swift.min(max, value))
    }
}
