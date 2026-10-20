import CoreGraphics
import Foundation
import Synchronization
import UniformTypeIdentifiers

extension Notification.Name {
    static let fileChanged = Notification.Name("ai.oxcraft.fileChanged")
}

nonisolated extension CodingUserInfoKey {
    static let profileScope = CodingUserInfoKey(rawValue: "profileScope")!
    static let fileDirectoryListing = CodingUserInfoKey(rawValue: "fileDirectoryListing")!
}

nonisolated final class FileDirectoryListing: Sendable {
    private let names = Mutex<[URL: [String]]>([:])
    let files: [String: FileItem]?

    init(files: [String: FileItem]? = nil) { self.files = files }

    func existingFilename(matching name: String, in directory: URL) -> String? {
        let listed = names.withLock { names in
            if let listed = names[directory] { return listed }
            let listed = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            names[directory] = listed
            return listed
        }
        return listed.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}

nonisolated public struct FileItem: Equatable, Sendable, Identifiable, Codable {
    nonisolated public enum Availability: String, Sendable, Equatable, Codable {
        case local
        case cloudOnly
        case downloading
        case unavailable
    }

    nonisolated public enum Kind: String, Sendable, Equatable, Codable {
        case image
        case pdf
        case text
        case html
        case file
    }

    public let fileName: String
    public let fileURL: URL
    public let availability: Availability
    private let listedSize: Int?
    private let listedCreatedAt: Date?
    private let listedModifiedAt: Date?

    public var id: String { fileName }
    public var displayName: String { fileURL.lastPathComponent }
    public var userFacingName: String { displayName }
    public var userFacingTypeName: String? {
        if kind == .html { return L10n.string("HTML") }
        if isMarkdown { return L10n.string("Markdown") }
        return contentType.localizedDescription
    }
    public var availabilityDescription: String? {
        switch availability {
        case .local: nil
        case .cloudOnly: L10n.string("In iCloud")
        case .downloading: L10n.string("Downloading…")
        case .unavailable: L10n.string("Unavailable")
        }
    }
    public var userFacingAccessibilityLabel: String {
        [userFacingName, userFacingTypeName, availabilityDescription]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
    public var typeIdentifier: String { contentType.identifier }
    public var mimeType: String { contentType.preferredMIMEType ?? "application/octet-stream" }
    public var isMarkdown: Bool {
        let suffix = fileURL.pathExtension.lowercased()
        return contentType.identifier == "net.daringfireball.markdown"
            || suffix == "md"
            || suffix == "markdown"
    }
    public var isVideo: Bool { contentType.conforms(to: .movie) }
    public var isSVG: Bool { contentType.conforms(to: .svg) }
    public var usesDedicatedPreview: Bool { kind == .html || isMarkdown }
    func updatingAvailability(_ availability: Availability) -> FileItem {
        FileItem(
            fileName: fileName,
            directory: fileURL.deletingLastPathComponent(),
            relativePath: fileURL.lastPathComponent,
            availability: availability,
            size: listedSize,
            createdAt: listedCreatedAt,
            modifiedAt: listedModifiedAt
        )
    }
    public var kind: Kind {
        if contentType.conforms(to: .html) { return .html }
        if contentType.conforms(to: .image), !contentType.conforms(to: .svg) { return .image }
        if contentType.conforms(to: .pdf) { return .pdf }
        if contentType.conforms(to: .text) || contentType.conforms(to: .sourceCode)
            || contentType.conforms(to: .json) || contentType.conforms(to: .commaSeparatedText) { return .text }
        return .file
    }
    public var exists: Bool { availability != .unavailable && resourceValues?.isRegularFile == true }
    public var size: Int? { listedSize ?? resourceValues?.fileSize }
    public var createdAt: Date? { listedCreatedAt ?? resourceValues?.creationDate }
    public var modifiedAt: Date? { listedModifiedAt ?? resourceValues?.contentModificationDate }

    init(
        fileName: String,
        directory: URL,
        relativePath: String? = nil,
        availability: Availability = .local,
        size: Int? = nil,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil
    ) {
        self.fileName = fileName
        fileURL = directory.appendingPathComponent(relativePath ?? fileName, isDirectory: false)
        self.availability = availability
        listedSize = size
        listedCreatedAt = createdAt
        listedModifiedAt = modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let scope = decoder.userInfo[.profileScope] as? ProfileScope ?? StorageRoot.currentScope
        guard let directory = scope?.root.appendingPathComponent("artifacts", isDirectory: true) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let fileName = try decoder.singleValueContainer().decode(String.self)
        let listing = decoder.userInfo[.fileDirectoryListing] as? FileDirectoryListing ?? FileDirectoryListing()
        if let files = listing.files {
            self = files[fileName] ?? files[fileName.lowercased()] ?? FileItem(fileName: fileName, directory: directory, availability: .unavailable)
        } else {
            self = try FileStore.file(named: fileName, in: directory, listing: listing)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(fileName)
    }

    private var contentType: UTType {
        return UTType(filenameExtension: fileURL.pathExtension) ?? .data
    }


    private var resourceValues: URLResourceValues? {
        try? fileURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
        ])
    }
}

nonisolated struct MarkdownFileDocument: Equatable, Sendable {
    let source: String
    let byteCount: Int
}

nonisolated public enum FileError: LocalizedError {
    case unsupportedType(String)
    case invalidFilename(String)
    case filenameExists(String)
    case missing(String)
    case changedSinceRead(String)
    case textNotFound
    case textAmbiguous(matches: Int)
    case textNotUTF8
    case textTooLarge(bytes: Int, limit: Int)
    case invalidPDF
    case encryptedPDF
    case pdfTooLarge(bytes: Int, limit: Int)
    case fileTooLarge(bytes: Int, limit: Int)
    case imageDecodeFailed
    case imageEncodeFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedType(let type): return String(format: L10n.string("Unsupported file type: %@", comment: ""), type)
        case .invalidFilename(let name): return String(format: L10n.string("Invalid filename: %@", comment: ""), name)
        case .filenameExists(let name): return String(format: L10n.string("A file named %@ already exists.", comment: ""), name)
        case .missing(let name): return String(format: L10n.string("Deleted file: %@", comment: ""), name)
        case .changedSinceRead(let name): return String(format: L10n.string("%@ changed after you opened it. Reopen it to see the latest version.", comment: ""), name)
        case .textNotFound: return L10n.string("The text to replace wasn't found.", comment: "")
        case .textAmbiguous(let matches): return String(format: L10n.string("The text to replace matched %lld locations; make it more specific.", comment: ""), matches)
        case .textNotUTF8: return L10n.string("Text file isn't UTF-8.", comment: "")
        case .textTooLarge(let bytes, let limit): return String(format: L10n.string("Text file too large (%lld bytes; limit %lld).", comment: ""), bytes, limit)
        case .invalidPDF: return L10n.string("Couldn't read the PDF.", comment: "")
        case .encryptedPDF: return L10n.string("Encrypted PDFs aren't supported.", comment: "")
        case .pdfTooLarge(let bytes, let limit): return String(format: L10n.string("PDF too large (%lld bytes; limit %lld).", comment: ""), bytes, limit)
        case .fileTooLarge(let bytes, let limit): return String(format: L10n.string("File too large (%lld bytes; limit %lld).", comment: ""), bytes, limit)
        case .imageDecodeFailed: return L10n.string("Couldn't decode the image.", comment: "")
        case .imageEncodeFailed: return L10n.string("Couldn't encode the image.", comment: "")
        }
    }
}

nonisolated public enum FileLimits {
    public static let textBytes = 200 * 1024
    public static let pdfBytes = 32 * 1024 * 1024
    public static let fileBytes = 32 * 1024 * 1024
    public static let imagePixels = 40_000_000
    public static let imageMaxDimension: CGFloat = 1568
    public static let imageJPEGQuality: CGFloat = 0.85
}
