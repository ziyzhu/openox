import CoreTransferable
import CryptoKit
import Foundation
import Observation
import Synchronization
import UniformTypeIdentifiers

extension UTType {
    nonisolated static let conversationPackage = UTType(exportedAs: AppConfiguration.conversationTypeIdentifier, conformingTo: .zip)
}

nonisolated struct ConversationPackageFiles: Sendable {
    let files: [String: ZipArchiveSource]
    let names: [String: String]
    let scratch: PackageScratch
}

nonisolated final class PackageScratch: Sendable {
    let directory: URL

    init() throws {
        directory = try FileStaging.createDirectory(in: FileManager.default.temporaryDirectory, prefix: "conversation-package-files")
    }

    deinit { FileStaging.cleanup(directory, operation: "conversation-package-files") }
}

nonisolated struct ConversationPackageDocument: Transferable, Sendable {
    let state: @Sendable () async throws -> ConversationState
    let fileName: String
    let scope: ProfileScope? = StorageRoot.currentScope
    let export = ConversationPackageExport()

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .conversationPackage) { document in
            SentTransferredFile(try await document.export.url { try await document.write() })
        }
        .suggestedFileName { "\($0.fileName).conversation" }
    }

    private func write() async throws -> URL {
        guard let scope else { throw CocoaError(.fileNoSuchFile) }
        let state = try await self.state()
        let files = try await ProfileRepository.shared.conversationPackageFiles(state, in: scope)
        FileStaging.cleanupStale(in: FileManager.default.temporaryDirectory, prefix: "conversation-export", olderThan: 600)
        let directory = try FileStaging.createDirectory(in: FileManager.default.temporaryDirectory, prefix: "conversation-export")
        let url = directory.appendingPathComponent("\(fileName).conversation", isDirectory: false)
        try await Task.detached(priority: .userInitiated) {
            try ConversationPackageCodec.encode(state, files: files.files, fileNames: files.names, to: url)
        }.value
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        Log.ui.info("ConversationPackage.export conversation=\(state.meta.id) turns=\(state.turns.count) bytes=\(bytes)")
        return url
    }
}

nonisolated final class ConversationPackageExport: Sendable {
    private let task = Mutex<Task<URL, any Error>?>(nil)

    func url(_ make: @escaping @Sendable () async throws -> URL) async throws -> URL {
        let (task, reused) = self.task.withLock { current in
            if let current { return (current, true) }
            let created = Task { try await make() }
            current = created
            return (created, false)
        }
        if reused { Log.ui.info("ConversationPackage.export reused") }
        do { return try await task.value }
        catch {
            self.task.withLock { if $0 == task { $0 = nil } }
            throw error
        }
    }
}

nonisolated struct ConversationPackageHeader: Codable, Equatable, Sendable {
    struct FileRecord: Codable, Equatable, Sendable {
        let path: String
        let bytes: Int
        let sha256: String
    }

    let packageVersion: Int
    let transcriptSchemaVersion: Int
    let title: String
    let createdAt: Date
    let lastActivity: Date?
    let exportedAt: Date
    let turnCount: Int
    let artifactCount: Int
    let hasContext: Bool
    let hasCompactedContext: Bool
    let serviceDomains: [String]
    let files: [FileRecord]
}

nonisolated struct ConversationPackagePayload: Sendable {
    let header: ConversationPackageHeader
    let turns: Data
    let context: Data?
    let files: [String: ZipArchiveSource]
    let scratch: PackageScratch
}

nonisolated struct PreparedConversationPackage: Sendable {
    let header: ConversationPackageHeader
    let turns: [Turn]
    let context: AgentContextCheckpoint?
    let contextBoundary: Int?
    let files: [String: ZipArchiveSource]
    let scratch: PackageScratch
}

nonisolated struct MaterializedConversationPackage: Sendable {
    let turns: [Turn]
    let context: AgentContextCheckpoint?
    let files: [String: Data]
}

nonisolated extension PreparedConversationPackage {
    func materialized(fileNames: [String: String], directory: URL, dependencyNames: [String: String]? = nil) throws -> MaterializedConversationPackage {
        var updatedTurns = turns
        for (source, destination) in fileNames {
            updatedTurns = updatedTurns.map {
                $0.replacingFile(named: source, with: destination, directory: directory)
            }
        }
        let updatedContext: AgentContextCheckpoint?
        if let context, let boundary = contextBoundary {
            let messages = context.messages.map { $0.replacingFiles(fileNames, directory: directory) }
            updatedContext = AgentContextCheckpoint(
                messages: messages,
                tokensBefore: context.tokensBefore,
                turns: updatedTurns,
                through: boundary
            )
        } else {
            updatedContext = nil
        }
        var updatedFiles: [String: Data] = [:]
        for (source, content) in files {
            guard case .data(let data) = content else { continue }
            let destination = fileNames[source.lowercased()] ?? source
            var rewritten = data
            if var text = String(data: data, encoding: .utf8) {
                for (originalKey, replacement) in dependencyNames ?? fileNames {
                    guard originalKey.caseInsensitiveCompare(replacement) != .orderedSame else { continue }
                    let original = files.keys.first { $0.lowercased() == originalKey } ?? originalKey
                    text = text.replacingOccurrences(of: original, with: replacement)
                    let encoded = original.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? original
                    let replacementEncoded = replacement.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? replacement
                    text = text.replacingOccurrences(of: encoded, with: replacementEncoded)
                }
                rewritten = Data(text.utf8)
            }
            updatedFiles[destination] = rewritten
        }
        guard updatedContext == nil || updatedContext?.boundary(in: updatedTurns) != nil else {
            throw ConversationPackageError.invalidContext
        }
        return MaterializedConversationPackage(turns: updatedTurns, context: updatedContext, files: updatedFiles)
    }
}

nonisolated struct ConversationImportProposal: Identifiable, Sendable {
    let id = UUID()
    let sourceName: String
    let payload: ConversationPackagePayload

    var header: ConversationPackageHeader { payload.header }
}

nonisolated enum ConversationPackageError: LocalizedError, Sendable {
    case tooLarge
    case invalidArchive
    case encrypted
    case unsupportedCompression
    case unsafePath
    case checksumMismatch
    case unsupportedVersion
    case invalidHeader
    case invalidTranscript
    case invalidContext
    case missingFile(String)
    case incompleteCompaction

    var errorDescription: String? {
        switch self {
        case .tooLarge: "This conversation package is too large."
        case .invalidArchive: "This isn't a valid conversation package."
        case .encrypted: "Encrypted conversation packages aren't supported."
        case .unsupportedCompression: "This conversation package uses unsupported compression."
        case .unsafePath: "This conversation package contains an unsafe path."
        case .checksumMismatch: "This conversation package appears to be damaged."
        case .unsupportedVersion: "This conversation package was made by an unsupported Ox version."
        case .invalidHeader: "This conversation package has an invalid header."
        case .invalidTranscript: "This conversation package has an invalid transcript."
        case .invalidContext: "This conversation package has invalid compacted context."
        case .missingFile(let name): "This conversation package is missing \(name)."
        case .incompleteCompaction: "This compacted conversation is missing its continuation context."
        }
    }
}

nonisolated enum ConversationPackageCodec {
    static let maximumPackageBytes = Int(UInt32.max)
    static let maximumEntryBytes = FileLimits.storedBytes
    private static let maximumHeaderBytes = 1024 * 1024
    static let maximumEntries = 256
    private static let packageVersion = 1
    private static let headerPath = "conversation.json"
    private static let legacyHeaderPath = "chat.json"
    private static let turnsPath = "turns.jsonl"
    private static let contextPath = "context.json"
    private static let artifactsPrefix = "artifacts/"

    static func encode(_ state: ConversationState, files: [String: ZipArchiveSource], fileNames: [String: String], to url: URL) throws {
        guard !state.turns.isEmpty else { throw ConversationPackageError.invalidTranscript }
        var prepared = try validate(turns: state.turns, context: state.context)
        if !fileNames.isEmpty {
            let directory = FileManager.default.temporaryDirectory
            var turns = prepared.turns
            for (source, destination) in fileNames { turns = turns.map { $0.replacingFile(named: source, with: destination, directory: directory) } }
            let context: AgentContextCheckpoint?
            if let retained = prepared.context, let boundary = prepared.contextBoundary {
                context = AgentContextCheckpoint(messages: retained.messages.map { $0.replacingFiles(fileNames, directory: directory) },
                    tokensBefore: retained.tokensBefore, turns: turns, through: boundary)
            } else { context = nil }
            prepared = try validate(turns: turns, context: context)
        }
        var bodyFiles: [(path: String, source: ZipArchiveSource)] = [(turnsPath, .data(try encodeTurns(prepared.turns)))]
        if let context = try prepared.context.map({ try JSONEncoder().encode($0) }) { bodyFiles.append((contextPath, .data(context))) }
        bodyFiles += files.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }.map { (artifactsPrefix + $0.key, $0.value) }
        try zip {
            let writer = try ZipArchiveWriter(url: url, maximumBytes: maximumPackageBytes)
            let records = try bodyFiles.map { file in
                let written = try writer.append(path: file.path, source: file.source)
                return ConversationPackageHeader.FileRecord(path: file.path, bytes: written.bytes, sha256: written.sha256)
            }
            let title = state.meta.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let header = ConversationPackageHeader(
                packageVersion: packageVersion,
                transcriptSchemaVersion: ConversationFormat.currentSchemaVersion,
                title: title.isEmpty ? "Conversation" : String(title.prefix(120)),
                createdAt: state.meta.createdAt,
                lastActivity: state.meta.lastActivity,
                exportedAt: Date(),
                turnCount: prepared.turns.count,
                artifactCount: files.count,
                hasContext: prepared.context != nil,
                hasCompactedContext: prepared.turns.requiresContextCheckpoint,
                serviceDomains: Array(Set(state.meta.attachedServiceDomains)).sorted(),
                files: records
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            _ = try writer.append(path: headerPath, source: .data(try encoder.encode(header)))
            try writer.finish()
        }
    }

    static func decode(_ data: Data, sourceName: String) throws -> ConversationImportProposal {
        let scratch = try PackageScratch()
        let files = try zip {
            try ZipArchiveCodec.decodeSources(
                data,
                maximumArchiveBytes: maximumPackageBytes,
                maximumEntryBytes: maximumEntryBytes,
                maximumEntries: maximumEntries,
                spillAbove: FileLimits.fileBytes,
                into: scratch.directory
            )
        }
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.source) })
        let headerKey = byPath[headerPath] == nil ? legacyHeaderPath : headerPath
        guard case .data(let headerData)? = byPath[headerKey], headerData.count <= maximumHeaderBytes else {
            throw ConversationPackageError.invalidHeader
        }
        let header: ConversationPackageHeader
        do {
            header = try JSONDecoder().decode(ConversationPackageHeader.self, from: headerData)
        } catch {
            throw ConversationPackageError.invalidHeader
        }
        guard header.packageVersion == packageVersion,
              header.transcriptSchemaVersion == ConversationFormat.currentSchemaVersion else {
            throw ConversationPackageError.unsupportedVersion
        }
        guard !header.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              header.turnCount > 0,
              header.artifactCount >= 0,
              header.files.count <= maximumEntries - 1 else {
            throw ConversationPackageError.invalidHeader
        }
        let payloadPaths = Set(byPath.keys.filter { $0 != headerKey })
        let declaredPaths = Set(header.files.map(\.path))
        guard payloadPaths == declaredPaths,
              declaredPaths.count == header.files.count else {
            throw ConversationPackageError.invalidHeader
        }
        for record in header.files {
            guard let body = byPath[record.path], try digest(body) == (record.bytes, record.sha256) else {
                throw ConversationPackageError.checksumMismatch
            }
        }
        guard case .data(let turns)? = byPath[turnsPath],
              header.hasContext == (byPath[contextPath] != nil) else {
            throw ConversationPackageError.invalidHeader
        }
        let context: Data?
        switch byPath[contextPath] {
        case .data(let value)?: context = value
        case nil: context = nil
        case .file?: throw ConversationPackageError.invalidContext
        }
        var packagedFiles: [String: ZipArchiveSource] = [:]
        for (path, body) in byPath where path.hasPrefix(artifactsPrefix) {
            let name = String(path.dropFirst(artifactsPrefix.count))
            guard !name.isEmpty,
                  !name.contains("/"),
                  try FileStore.validatedFilename(name) == name,
                  packagedFiles[name.lowercased()] == nil else {
                throw ConversationPackageError.invalidHeader
            }
            packagedFiles[name] = body
        }
        guard packagedFiles.count == header.artifactCount,
              payloadPaths.allSatisfy({ $0 == turnsPath || $0 == contextPath || $0.hasPrefix(artifactsPrefix) }) else {
            throw ConversationPackageError.invalidHeader
        }
        let payload = ConversationPackagePayload(
            header: header,
            turns: turns,
            context: context,
            files: packagedFiles,
            scratch: scratch
        )
        _ = try prepare(payload)
        return ConversationImportProposal(sourceName: sourceName, payload: payload)
    }

    static func prepare(_ payload: ConversationPackagePayload) throws -> PreparedConversationPackage {
        let root = try FileStaging.createDirectory(
            in: FileManager.default.temporaryDirectory,
            prefix: "conversation-package"
        )
        let directory = root.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { FileStaging.cleanup(root, operation: "conversation-package") }
        for (name, source) in payload.files {
            let destination = directory.appendingPathComponent(name, isDirectory: false)
            switch source {
            case .data(let data): try data.write(to: destination, options: .atomic)
            case .file(let url): try FileManager.default.copyItem(at: url, to: destination)
            }
        }
        let scope = ProfileScope(profileID: UUID(), root: root, location: .local)
        let decoder = JSONDecoder()
        decoder.userInfo[.profileScope] = scope
        let turns: [Turn]
        do {
            let lines = payload.turns.split(separator: 0x0A, omittingEmptySubsequences: true)
            turns = try lines.map { try decoder.decode(Turn.self, from: Data($0)) }
        } catch {
            throw ConversationPackageError.invalidTranscript
        }
        let context: AgentContextCheckpoint?
        do {
            context = try payload.context.map { try decoder.decode(AgentContextCheckpoint.self, from: $0) }
        } catch {
            throw ConversationPackageError.invalidContext
        }
        let prepared = try validate(turns: turns, context: context)
        guard prepared.turns.count == payload.header.turnCount,
              prepared.turns.requiresContextCheckpoint == payload.header.hasCompactedContext else {
            throw ConversationPackageError.invalidHeader
        }
        let packaged = Set(payload.files.keys.map { $0.lowercased() })
        for file in referencedFiles(turns: prepared.turns, context: prepared.context) {
            guard packaged.contains(file.fileName.lowercased()) else {
                throw ConversationPackageError.missingFile(file.fileName)
            }
        }
        return PreparedConversationPackage(
            header: payload.header,
            turns: prepared.turns,
            context: prepared.context,
            contextBoundary: prepared.contextBoundary,
            files: payload.files,
            scratch: payload.scratch
        )
    }

    private static func validate(
        turns: [Turn],
        context: AgentContextCheckpoint?
    ) throws -> (turns: [Turn], context: AgentContextCheckpoint?, contextBoundary: Int?) {
        guard !turns.isEmpty, ConversationFormat.normalize(turns) == turns else {
            throw ConversationPackageError.invalidTranscript
        }
        var document = ConversationDocument(turns: turns)
        document.apply(.sealAllTurns)
        guard document.turns == turns else { throw ConversationPackageError.invalidTranscript }
        let compacted = turns.requiresContextCheckpoint
        guard !compacted || context != nil else { throw ConversationPackageError.incompleteCompaction }
        let retainedContext = compacted ? context : nil
        let boundary = retainedContext?.boundary(in: turns)
        guard retainedContext == nil || boundary != nil else { throw ConversationPackageError.invalidContext }
        return (turns, retainedContext, boundary)
    }

    private static func encodeTurns(_ turns: [Turn]) throws -> Data {
        let encoder = JSONEncoder()
        return try turns.reduce(into: Data()) { data, turn in
            data.append(try encoder.encode(turn))
            data.append(0x0A)
        }
    }

    static func referencedFiles(turns: [Turn], context: AgentContextCheckpoint?) -> [FileItem] {
        var result: [FileItem] = []
        for turn in turns {
            switch turn {
            case .user(let value, _):
                result += value.attachments
            case .agent(let value, _):
                for generation in value.generations {
                    result += generation.assistantMessage?.content.compactMap(\.attachedFile) ?? []
                }
                for step in value.steps {
                    result += step.toolResult?.content.compactMap(\.attachedFile) ?? []
                    guard case .execute(let execution) = step.kind else { continue }
                    for effect in execution.effects {
                        switch effect {
                        case .artifact(let file), .media(let file): result.append(file)
                        case .shoveler(let shoveler): result += shoveler.cards.compactMap(\.artifact)
                        case .video(let video): result += video.source.artifact.map { [$0] } ?? []
                        case .image(let image): result += image.source.artifact.map { [$0] } ?? []
                        case .invocation, .progress, .serviceControl, .serviceInspector, .skill: break
                        }
                    }
                }
            }
        }
        for message in context?.messages ?? [] { result += message.attachedFiles }
        var seen = Set<String>()
        return result.filter { seen.insert($0.fileName.lowercased()).inserted }
    }

    private static func digest(_ source: ZipArchiveSource) throws -> (Int, String) {
        var hash = SHA256()
        var bytes = 0
        switch source {
        case .data(let data):
            hash.update(data: data)
            bytes = data.count
        case .file(let url):
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                hash.update(data: chunk)
                bytes += chunk.count
            }
        }
        return (bytes, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func zip<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch let error as ZipArchiveError {
            switch error {
            case .tooLarge: throw ConversationPackageError.tooLarge
            case .invalidArchive: throw ConversationPackageError.invalidArchive
            case .encrypted: throw ConversationPackageError.encrypted
            case .unsupportedCompression: throw ConversationPackageError.unsupportedCompression
            case .unsafePath: throw ConversationPackageError.unsafePath
            case .checksumMismatch: throw ConversationPackageError.checksumMismatch
            }
        }
    }
}

extension ProfileRepository {
    func conversationPackageFiles(_ state: ConversationState, in scope: ProfileScope) async throws -> ConversationPackageFiles {
        let inventory = try await profileFiles(prefix: "", in: scope).filter { $0.reference != nil }
        var pending: [DurableProfileFile] = []
        var names: [String: String] = [:]
        for referenced in ConversationPackageCodec.referencedFiles(turns: state.turns, context: state.context) {
            guard let file = inventory.first(where: { $0.reference == referenced.fileName }) ?? inventory.first(where: { $0.aliases?.contains(referenced.fileName) == true }) else {
                throw ConversationPackageError.missingFile(referenced.fileName)
            }
            names[referenced.fileName.lowercased()] = Self.packageFileName(file)
            if !pending.contains(where: { $0.reference == file.reference }) { pending.append(file) }
        }
        let scratch = try PackageScratch()
        var result: [String: ZipArchiveSource] = [:]
        var total = 0
        while !pending.isEmpty {
            let file = pending.removeFirst(), name = Self.packageFileName(file)
            if result[name] != nil { continue }
            guard result.count < ConversationPackageCodec.maximumEntries - 3,
                  file.size <= ConversationPackageCodec.maximumEntryBytes, file.size <= ConversationPackageCodec.maximumPackageBytes - total else { throw ConversationPackageError.tooLarge }
            let descriptor = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(file))
            total += file.size
            if file.size > FileLimits.fileBytes {
                let copy = scratch.directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
                try await DurableProfileStore.shared.copyFile(scope: scope, file: descriptor, to: copy)
                result[name] = .file(copy)
                continue
            }
            let data = try await DurableProfileStore.shared.readFile(scope: scope, file: descriptor)
            if var text = String(data: data, encoding: .utf8), data.count <= FileLimits.textBytes {
                for candidate in inventory where candidate.path != file.path {
                    let relative = Self.relativeFilePath(from: file.path, to: candidate.path)
                    let encoded = relative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relative
                    guard text.contains(relative) || text.contains(encoded) else { continue }
                    let destination = Self.packageFileName(candidate)
                    text = text.replacingOccurrences(of: encoded, with: destination)
                    if encoded != relative { text = text.replacingOccurrences(of: relative, with: destination) }
                    if result[destination] == nil && !pending.contains(where: { $0.reference == candidate.reference }) { pending.append(candidate) }
                    guard pending.count + result.count < ConversationPackageCodec.maximumEntries - 3 else { throw ConversationPackageError.tooLarge }
                }
                result[name] = .data(Data(text.utf8))
            } else { result[name] = .data(data) }
        }
        Log.app.info("ConversationPackage.files profile=\(scope.profileID?.uuidString ?? "temporary") files=\(result.count) bytes=\(total)")
        return ConversationPackageFiles(files: result, names: names, scratch: scratch)
    }

    nonisolated private static func packageFileName(_ file: DurableProfileFile) -> String {
        let identity = URL(fileURLWithPath: file.reference!).deletingPathExtension().lastPathComponent
        let suffix = URL(fileURLWithPath: file.path).pathExtension
        return identity + (suffix.isEmpty ? "" : "." + suffix)
    }

    nonisolated private static func relativeFilePath(from: String, to: String) -> String {
        var source = from.split(separator: "/").dropLast().map(String.init)
        var destination = to.split(separator: "/").map(String.init)
        while !source.isEmpty, source.first == destination.first { source.removeFirst(); destination.removeFirst() }
        return (Array(repeating: "..", count: source.count) + destination).joined(separator: "/")
    }
}

private nonisolated extension ContentBlock {
    var attachedFile: FileItem? {
        if case .attachment(let file) = self { return file }
        return nil
    }

    func replacingFiles(_ names: [String: String], directory: URL) -> ContentBlock {
        guard case .attachment(let file) = self,
              let name = names[file.fileName.lowercased()] else { return self }
        return .attachment(FileItem(fileName: name, directory: directory))
    }
}

private nonisolated extension Message {
    var attachedFiles: [FileItem] {
        switch self {
        case .system: []
        case .user(let value): value.content.compactMap(\.attachedFile)
        case .assistant(let value): value.content.compactMap(\.attachedFile)
        case .toolResult(let value): value.content.compactMap(\.attachedFile)
        }
    }

    func replacingFiles(_ names: [String: String], directory: URL) -> Message {
        switch self {
        case .system:
            return self
        case .user(var value):
            value.content = value.content.map { $0.replacingFiles(names, directory: directory) }
            return .user(value)
        case .assistant(var value):
            value.content = value.content.map { $0.replacingFiles(names, directory: directory) }
            return .assistant(value)
        case .toolResult(var value):
            value.content = value.content.map { $0.replacingFiles(names, directory: directory) }
            return .toolResult(value)
        }
    }
}

@MainActor
@Observable
final class ConversationImportCoordinator {
    private enum State {
        case idle
        case loading(Task<Void, Never>)
        case reviewing(ConversationImportProposal)
        case saving(ConversationImportProposal)
        case imported(UUID)
    }

    private var state = State.idle
    private(set) var errorMessage: String?
    var proposal: ConversationImportProposal? {
        switch state {
        case .reviewing(let proposal), .saving(let proposal): proposal
        case .idle, .loading, .imported: nil
        }
    }
    var isLoading: Bool {
        if case .loading = state { true } else { false }
    }
    var isSaving: Bool {
        if case .saving = state { true } else { false }
    }
    var importedConversationID: UUID? {
        if case .imported(let id) = state { id } else { nil }
    }

    func receive(_ url: URL) {
        guard !isSaving else {
            errorMessage = "Wait for the current conversation import to finish."
            Log.ui.info("ConversationImport.rejected reason=saving source=\(url.lastPathComponent)")
            return
        }
        if case .loading(let operation) = state { operation.cancel() }
        let request = UUID()
        errorMessage = nil
        state = .loading(Task {
            do {
                let proposal = try await Task.detached(priority: .userInitiated) {
                    guard ["conversation", "chat"].contains(url.pathExtension.lowercased()) else { throw ConversationPackageError.invalidArchive }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                       size > ConversationPackageCodec.maximumPackageBytes {
                        throw ConversationPackageError.tooLarge
                    }
                    let data = try Data(contentsOf: url, options: .alwaysMapped)
                    return try ConversationPackageCodec.decode(data, sourceName: url.lastPathComponent)
                }.value
                guard !Task.isCancelled else { return }
                state = .reviewing(proposal)
                Log.ui.info("ConversationImport.ready request=\(request) title=\(proposal.header.title) source=\(proposal.sourceName)")
            } catch {
                guard !Task.isCancelled else { return }
                state = .idle
                errorMessage = error.localizedDescription
                Log.ui.error("ConversationImport.open request=\(request) source=\(url.lastPathComponent) failed=\(error.localizedDescription)")
            }
        })
    }

    func install(using conversations: ConversationManager) {
        guard case .reviewing(let proposal) = state else { return }
        state = .saving(proposal)
        Task {
            do {
                let conversation = try await conversations.importPackage(proposal.payload)
                state = .imported(conversation.id)
                Log.ui.info("ConversationImport.saved conversation=\(conversation.id) title=\(proposal.header.title)")
            } catch {
                state = .reviewing(proposal)
                errorMessage = error.localizedDescription
                Log.ui.error("ConversationImport.save title=\(proposal.header.title) failed=\(error.localizedDescription)")
            }
        }
    }

    func dismissProposal() {
        guard case .reviewing = state else { return }
        state = .idle
    }

    func dismissError() { errorMessage = nil }
    func consumeImportedConversation() {
        guard case .imported = state else { return }
        state = .idle
    }
}
