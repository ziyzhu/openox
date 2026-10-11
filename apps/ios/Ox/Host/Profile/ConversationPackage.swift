import CoreTransferable
import CryptoKit
import Foundation
import Observation
import UniformTypeIdentifiers

extension UTType {
    nonisolated static let conversationPackage = UTType(exportedAs: AppConfiguration.conversationTypeIdentifier, conformingTo: .zip)
}

nonisolated struct ConversationPackageFiles: Sendable {
    let data: [String: Data]
    let names: [String: String]
}

nonisolated struct ConversationPackageDocument: Transferable, Sendable {
    let state: ConversationState
    let fileName: String
    let scope: ProfileScope? = StorageRoot.currentScope

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .conversationPackage) { document in
            guard let scope = document.scope else { throw CocoaError(.fileNoSuchFile) }
            let files = try await ProfileRepository.shared.conversationPackageFiles(document.state, in: scope)
            let data = try await Task.detached(priority: .userInitiated) {
                try ConversationPackageCodec.encode(document.state, files: files.data, fileNames: files.names)
            }.value
            Log.ui.info("ConversationPackage.export chat=\(document.state.meta.id) turns=\(document.state.turns.count) bytes=\(data.count)")
            return data
        }
        .suggestedFileName { "\($0.fileName).conversation" }
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
    let artifacts: [String: Data]
}

nonisolated struct PreparedConversationPackage: Sendable {
    let header: ConversationPackageHeader
    let turns: [Turn]
    let context: AgentContextCheckpoint?
    let contextBoundary: Int?
    let artifacts: [String: Data]
}

nonisolated struct MaterializedConversationPackage: Sendable {
    let turns: [Turn]
    let context: AgentContextCheckpoint?
    let artifacts: [String: Data]
}

nonisolated extension PreparedConversationPackage {
    func materialized(artifactNames: [String: String], directory: URL, dependencyNames: [String: String]? = nil) throws -> MaterializedConversationPackage {
        var updatedTurns = turns
        for (source, destination) in artifactNames {
            updatedTurns = updatedTurns.map {
                $0.replacingFile(named: source, with: destination, directory: directory)
            }
        }
        let updatedContext: AgentContextCheckpoint?
        if let context, let boundary = contextBoundary {
            let messages = context.messages.map { $0.replacingFiles(artifactNames, directory: directory) }
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
        for (source, data) in artifacts {
            let destination = artifactNames[source.lowercased()] ?? source
            var rewritten = data
            if var text = String(data: data, encoding: .utf8) {
                for (originalKey, replacement) in dependencyNames ?? artifactNames {
                    guard originalKey.caseInsensitiveCompare(replacement) != .orderedSame else { continue }
                    let original = artifacts.keys.first { $0.lowercased() == originalKey } ?? originalKey
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
        return MaterializedConversationPackage(turns: updatedTurns, context: updatedContext, artifacts: updatedFiles)
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
        case .invalidHeader: "This conversation package has an invalid chat.json."
        case .invalidTranscript: "This conversation package has an invalid transcript."
        case .invalidContext: "This conversation package has invalid compacted context."
        case .missingFile(let name): "This conversation package is missing \(name)."
        case .incompleteCompaction: "This compacted conversation is missing its continuation context."
        }
    }
}

nonisolated enum ConversationPackageCodec {
    static let maximumPackageBytes = 128 * 1024 * 1024
    static let maximumEntryBytes = 32 * 1024 * 1024
    private static let maximumHeaderBytes = 1024 * 1024
    static let maximumEntries = 256
    private static let packageVersion = 1
    private static let headerPath = "chat.json"
    private static let turnsPath = "turns.jsonl"
    private static let contextPath = "context.json"
    private static let artifactsPrefix = "artifacts/"

    static func encode(_ state: ConversationState, files: [String: Data]? = nil, fileNames: [String: String] = [:]) throws -> Data {
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
        let turns = try encodeTurns(prepared.turns)
        let context = try prepared.context.map { try JSONEncoder().encode($0) }
        let artifacts: [String: Data]
        if let files { artifacts = files }
        else {
            let directFiles = try artifactData(turns: prepared.turns, context: prepared.context)
            artifacts = try includingFileDependencies(directFiles.data, directory: directFiles.directory)
        }

        var bodyFiles = [ZipArchiveCodec.File(path: turnsPath, data: turns)]
        if let context { bodyFiles.append(.init(path: contextPath, data: context)) }
        bodyFiles += artifacts.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }.map {
            ZipArchiveCodec.File(path: artifactsPrefix + $0.key, data: $0.value)
        }
        let records = bodyFiles.map {
            ConversationPackageHeader.FileRecord(path: $0.path, bytes: $0.data.count, sha256: sha256($0.data))
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
            artifactCount: artifacts.count,
            hasContext: context != nil,
            hasCompactedContext: prepared.turns.requiresContextCheckpoint,
            serviceDomains: Array(Set(state.meta.attachedServiceDomains)).sorted(),
            files: records
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        bodyFiles.insert(.init(path: headerPath, data: try encoder.encode(header)), at: 0)
        return try zip {
            try ZipArchiveCodec.encode(bodyFiles, maximumArchiveBytes: maximumPackageBytes)
        }
    }

    static func decode(_ data: Data, sourceName: String) throws -> ConversationImportProposal {
        let files = try zip {
            try ZipArchiveCodec.decode(
                data,
                maximumArchiveBytes: maximumPackageBytes,
                maximumEntryBytes: maximumEntryBytes,
                maximumEntries: maximumEntries
            )
        }
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.data) })
        guard let headerData = byPath[headerPath], headerData.count <= maximumHeaderBytes else {
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
        let payloadPaths = Set(byPath.keys.filter { $0 != headerPath })
        let declaredPaths = Set(header.files.map(\.path))
        guard payloadPaths == declaredPaths,
              declaredPaths.count == header.files.count else {
            throw ConversationPackageError.invalidHeader
        }
        for record in header.files {
            guard let body = byPath[record.path],
                  body.count == record.bytes,
                  sha256(body) == record.sha256 else {
                throw ConversationPackageError.checksumMismatch
            }
        }
        guard let turns = byPath[turnsPath],
              header.hasContext == (byPath[contextPath] != nil) else {
            throw ConversationPackageError.invalidHeader
        }
        var artifacts: [String: Data] = [:]
        for (path, body) in byPath where path.hasPrefix(artifactsPrefix) {
            let name = String(path.dropFirst(artifactsPrefix.count))
            guard !name.isEmpty,
                  !name.contains("/"),
                  try FileStore.validatedFilename(name) == name,
                  artifacts[name.lowercased()] == nil else {
                throw ConversationPackageError.invalidHeader
            }
            artifacts[name] = body
        }
        guard artifacts.count == header.artifactCount,
              payloadPaths.allSatisfy({ $0 == turnsPath || $0 == contextPath || $0.hasPrefix(artifactsPrefix) }) else {
            throw ConversationPackageError.invalidHeader
        }
        let payload = ConversationPackagePayload(
            header: header,
            turns: turns,
            context: byPath[contextPath],
            artifacts: artifacts
        )
        _ = try prepare(payload)
        return ConversationImportProposal(sourceName: sourceName, payload: payload)
    }

    static func prepare(_ payload: ConversationPackagePayload) throws -> PreparedConversationPackage {
        let root = try FileStaging.createDirectory(
            in: FileManager.default.temporaryDirectory,
            prefix: "chat-package"
        )
        let directory = root.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { FileStaging.cleanup(root, operation: "chat-package") }
        for (name, data) in payload.artifacts {
            try data.write(to: directory.appendingPathComponent(name, isDirectory: false), options: .atomic)
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
        let packaged = Set(payload.artifacts.keys.map { $0.lowercased() })
        for artifact in referencedFiles(turns: prepared.turns, context: prepared.context) {
            guard packaged.contains(artifact.fileName.lowercased()) else {
                throw ConversationPackageError.missingFile(artifact.fileName)
            }
        }
        return PreparedConversationPackage(
            header: payload.header,
            turns: prepared.turns,
            context: prepared.context,
            contextBoundary: prepared.contextBoundary,
            artifacts: payload.artifacts
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

    private static func artifactData(
        turns: [Turn],
        context: AgentContextCheckpoint?
    ) throws -> (data: [String: Data], directory: URL?) {
        var result: [String: Data] = [:]
        let referenced = referencedFiles(turns: turns, context: context)
        for artifact in referenced {
            let key = artifact.fileName.lowercased()
            guard !result.keys.contains(where: { $0.lowercased() == key }) else { continue }
            guard artifact.exists else { throw ConversationPackageError.missingFile(artifact.fileName) }
            let data = try Data(contentsOf: artifact.fileURL, options: .mappedIfSafe)
            guard data.count <= maximumEntryBytes else { throw ConversationPackageError.tooLarge }
            result[artifact.fileName] = data
        }
        return (result, referenced.first?.fileURL.deletingLastPathComponent())
    }

    private static func includingFileDependencies(_ direct: [String: Data], directory: URL?) throws -> [String: Data] {
        guard let directory else { return direct }
        let candidates = FileStore.list(in: directory).filter { artifact in
            let type = UTType(filenameExtension: artifact.fileURL.pathExtension) ?? .data
            return type.conforms(to: .image) || type.conforms(to: .audio) || type.conforms(to: .movie)
        }
        var result = direct
        var changed = true
        while changed {
            changed = false
            let sources = result.values.compactMap { String(data: $0, encoding: .utf8) }
            for candidate in candidates where !result.keys.contains(where: { $0.caseInsensitiveCompare(candidate.fileName) == .orderedSame }) {
                let encoded = candidate.fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? candidate.fileName
                guard sources.contains(where: { $0.contains(candidate.fileName) || $0.contains(encoded) }) else { continue }
                let data = try Data(contentsOf: candidate.fileURL, options: .mappedIfSafe)
                guard data.count <= maximumEntryBytes else { throw ConversationPackageError.tooLarge }
                result[candidate.fileName] = data
                changed = true
            }
        }
        return result
    }

    static func referencedFiles(turns: [Turn], context: AgentContextCheckpoint?) -> [FileItem] {
        var result: [FileItem] = []
        for turn in turns {
            switch turn {
            case .user(let value, _):
                result += value.attachments
            case .agent(let value, _):
                for generation in value.generations {
                    result += generation.assistantMessage?.content.compactMap(\.artifact) ?? []
                }
                for step in value.steps {
                    result += step.toolResult?.content.compactMap(\.artifact) ?? []
                    guard case .execute(let execution) = step.kind else { continue }
                    for effect in execution.effects {
                        switch effect {
                        case .artifact(let artifact), .media(let artifact): result.append(artifact)
                        case .shoveler(let shoveler): result += shoveler.cards.compactMap(\.artifact)
                        case .video(let video): result += video.source.artifact.map { [$0] } ?? []
                        case .image(let image): result += image.source.artifact.map { [$0] } ?? []
                        case .invocation, .progress, .serviceControl, .serviceInspector, .skill: break
                        }
                    }
                }
            }
        }
        for message in context?.messages ?? [] { result += message.artifacts }
        var seen = Set<String>()
        return result.filter { seen.insert($0.fileName.lowercased()).inserted }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
        for artifact in ConversationPackageCodec.referencedFiles(turns: state.turns, context: state.context) {
            guard let file = inventory.first(where: { $0.reference == artifact.fileName }) ?? inventory.first(where: { $0.aliases?.contains(artifact.fileName) == true }) else {
                throw ConversationPackageError.missingFile(artifact.fileName)
            }
            names[artifact.fileName.lowercased()] = Self.packageFileName(file)
            if !pending.contains(where: { $0.reference == file.reference }) { pending.append(file) }
        }
        var result: [String: Data] = [:]
        var total = 0
        while !pending.isEmpty {
            let file = pending.removeFirst(), name = Self.packageFileName(file)
            if result[name] != nil { continue }
            guard result.count < ConversationPackageCodec.maximumEntries - 3,
                  file.size <= ConversationPackageCodec.maximumEntryBytes, file.size <= ConversationPackageCodec.maximumPackageBytes - total else { throw ConversationPackageError.tooLarge }
            let descriptor = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(file))
            let data = try await DurableProfileStore.shared.readFile(scope: scope, file: descriptor)
            total += data.count
            guard total <= ConversationPackageCodec.maximumPackageBytes else { throw ConversationPackageError.tooLarge }
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
                result[name] = Data(text.utf8)
            } else { result[name] = data }
        }
        Log.app.info("ConversationPackage.files profile=\(scope.profileID?.uuidString ?? "temporary") files=\(result.count) bytes=\(total)")
        return ConversationPackageFiles(data: result, names: names)
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
    var artifact: FileItem? {
        if case .attachment(let artifact) = self { return artifact }
        return nil
    }

    func replacingFiles(_ names: [String: String], directory: URL) -> ContentBlock {
        guard case .attachment(let artifact) = self,
              let name = names[artifact.fileName.lowercased()] else { return self }
        return .attachment(FileItem(fileName: name, directory: directory))
    }
}

private nonisolated extension Message {
    var artifacts: [FileItem] {
        switch self {
        case .user(let value): value.content.compactMap(\.artifact)
        case .assistant(let value): value.content.compactMap(\.artifact)
        case .toolResult(let value): value.content.compactMap(\.artifact)
        }
    }

    func replacingFiles(_ names: [String: String], directory: URL) -> Message {
        switch self {
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
    private(set) var proposal: ConversationImportProposal?
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var importedConversationID: UUID?
    @ObservationIgnored private var operation: Task<Void, Never>?

    func receive(_ url: URL) {
        operation?.cancel()
        let request = UUID()
        isLoading = true
        isSaving = false
        proposal = nil
        errorMessage = nil
        importedConversationID = nil
        operation = Task {
            do {
                let proposal = try await Task.detached(priority: .userInitiated) {
                    guard url.pathExtension.lowercased() == "chat" else { throw ConversationPackageError.invalidArchive }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                       size > ConversationPackageCodec.maximumPackageBytes {
                        throw ConversationPackageError.tooLarge
                    }
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    return try ConversationPackageCodec.decode(data, sourceName: url.lastPathComponent)
                }.value
                guard !Task.isCancelled else { return }
                self.proposal = proposal
                isLoading = false
                Log.ui.info("ConversationImport.ready request=\(request) title=\(proposal.header.title) source=\(proposal.sourceName)")
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                isLoading = false
                errorMessage = error.localizedDescription
                Log.ui.error("ConversationImport.open request=\(request) source=\(url.lastPathComponent) failed=\(error.localizedDescription)")
            }
        }
    }

    func install(using conversations: ConversationManager) {
        guard let proposal else { return }
        isSaving = true
        operation = Task {
            do {
                let conversation = try await conversations.importPackage(proposal.payload)
                guard !Task.isCancelled else { return }
                self.proposal = nil
                isSaving = false
                importedConversationID = conversation.id
                Log.ui.info("ConversationImport.saved chat=\(conversation.id) title=\(proposal.header.title)")
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                isSaving = false
                errorMessage = error.localizedDescription
                Log.ui.error("ConversationImport.save title=\(proposal.header.title) failed=\(error.localizedDescription)")
            }
        }
    }

    func dismissProposal() {
        guard !isSaving else { return }
        proposal = nil
    }

    func dismissError() { errorMessage = nil }
    func consumeImportedConversation() { importedConversationID = nil }
}
