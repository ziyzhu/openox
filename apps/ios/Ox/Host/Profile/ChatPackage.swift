import CoreTransferable
import CryptoKit
import Foundation
import Observation
import UniformTypeIdentifiers

extension UTType {
    nonisolated static let chatPackage = UTType(exportedAs: AppConfiguration.chatTypeIdentifier, conformingTo: .zip)
}

nonisolated struct ChatPackageDocument: Transferable, Sendable {
    let state: ChatState
    let fileName: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .chatPackage) { document in
            let data = try await Task.detached(priority: .userInitiated) {
                try ChatPackageCodec.encode(document.state)
            }.value
            Log.ui.info("ChatPackage.export chat=\(document.state.meta.id) turns=\(document.state.turns.count) bytes=\(data.count)")
            return data
        }
        .suggestedFileName { "\($0.fileName).chat" }
    }
}

nonisolated struct ChatPackageHeader: Codable, Equatable, Sendable {
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

nonisolated struct ChatPackagePayload: Sendable {
    let header: ChatPackageHeader
    let turns: Data
    let context: Data?
    let artifacts: [String: Data]
}

nonisolated struct PreparedChatPackage: Sendable {
    let header: ChatPackageHeader
    let turns: [Turn]
    let context: AgentContextCheckpoint?
    let contextBoundary: Int?
    let artifacts: [String: Data]
}

nonisolated struct MaterializedChatPackage: Sendable {
    let turns: [Turn]
    let context: AgentContextCheckpoint?
    let artifacts: [String: Data]
}

nonisolated extension PreparedChatPackage {
    func materialized(artifactNames: [String: String], directory: URL) throws -> MaterializedChatPackage {
        var updatedTurns = turns
        for (source, destination) in artifactNames {
            updatedTurns = updatedTurns.map {
                $0.replacingArtifact(named: source, with: destination, directory: directory)
            }
        }
        let updatedContext: AgentContextCheckpoint?
        if let context, let boundary = contextBoundary {
            let messages = context.messages.map { $0.replacingArtifacts(artifactNames, directory: directory) }
            updatedContext = AgentContextCheckpoint(
                messages: messages,
                tokensBefore: context.tokensBefore,
                turns: updatedTurns,
                through: boundary
            )
        } else {
            updatedContext = nil
        }
        var updatedArtifacts: [String: Data] = [:]
        for (source, data) in artifacts {
            let destination = artifactNames[source.lowercased()] ?? source
            var rewritten = data
            if var text = String(data: data, encoding: .utf8) {
                for (originalKey, replacement) in artifactNames {
                    guard originalKey.caseInsensitiveCompare(replacement) != .orderedSame else { continue }
                    let original = artifacts.keys.first { $0.lowercased() == originalKey } ?? originalKey
                    text = text.replacingOccurrences(of: original, with: replacement)
                    let encoded = original.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? original
                    let replacementEncoded = replacement.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? replacement
                    text = text.replacingOccurrences(of: encoded, with: replacementEncoded)
                }
                rewritten = Data(text.utf8)
            }
            updatedArtifacts[destination] = rewritten
        }
        guard updatedContext == nil || updatedContext?.boundary(in: updatedTurns) != nil else {
            throw ChatPackageError.invalidContext
        }
        return MaterializedChatPackage(turns: updatedTurns, context: updatedContext, artifacts: updatedArtifacts)
    }
}

nonisolated struct ChatImportProposal: Identifiable, Sendable {
    let id = UUID()
    let sourceName: String
    let payload: ChatPackagePayload

    var header: ChatPackageHeader { payload.header }
}

nonisolated enum ChatPackageError: LocalizedError, Sendable {
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
    case missingArtifact(String)
    case incompleteCompaction

    var errorDescription: String? {
        switch self {
        case .tooLarge: "This chat package is too large."
        case .invalidArchive: "This isn't a valid chat package."
        case .encrypted: "Encrypted chat packages aren't supported."
        case .unsupportedCompression: "This chat package uses unsupported compression."
        case .unsafePath: "This chat package contains an unsafe path."
        case .checksumMismatch: "This chat package appears to be damaged."
        case .unsupportedVersion: "This chat package was made by an unsupported Ox version."
        case .invalidHeader: "This chat package has an invalid chat.json."
        case .invalidTranscript: "This chat package has an invalid transcript."
        case .invalidContext: "This chat package has invalid compacted context."
        case .missingArtifact(let name): "This chat package is missing \(name)."
        case .incompleteCompaction: "This compacted chat is missing its continuation context."
        }
    }
}

nonisolated enum ChatPackageCodec {
    static let maximumPackageBytes = 128 * 1024 * 1024
    static let maximumEntryBytes = 32 * 1024 * 1024
    private static let maximumHeaderBytes = 1024 * 1024
    private static let maximumEntries = 256
    private static let packageVersion = 1
    private static let headerPath = "chat.json"
    private static let turnsPath = "turns.jsonl"
    private static let contextPath = "context.json"
    private static let artifactsPrefix = "artifacts/"

    static func encode(_ state: ChatState) throws -> Data {
        guard !state.turns.isEmpty else { throw ChatPackageError.invalidTranscript }
        let prepared = try validate(turns: state.turns, context: state.context)
        let turns = try encodeTurns(prepared.turns)
        let context = try prepared.context.map { try JSONEncoder().encode($0) }
        let directArtifacts = try artifactData(turns: prepared.turns, context: prepared.context)
        let artifacts = try includingArtifactDependencies(directArtifacts.data, directory: directArtifacts.directory)

        var bodyFiles = [ZipArchiveCodec.File(path: turnsPath, data: turns)]
        if let context { bodyFiles.append(.init(path: contextPath, data: context)) }
        bodyFiles += artifacts.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }.map {
            ZipArchiveCodec.File(path: artifactsPrefix + $0.key, data: $0.value)
        }
        let records = bodyFiles.map {
            ChatPackageHeader.FileRecord(path: $0.path, bytes: $0.data.count, sha256: sha256($0.data))
        }
        let title = state.meta.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = ChatPackageHeader(
            packageVersion: packageVersion,
            transcriptSchemaVersion: ChatFormat.currentSchemaVersion,
            title: title.isEmpty ? "Chat" : String(title.prefix(120)),
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

    static func decode(_ data: Data, sourceName: String) throws -> ChatImportProposal {
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
            throw ChatPackageError.invalidHeader
        }
        let header: ChatPackageHeader
        do {
            header = try JSONDecoder().decode(ChatPackageHeader.self, from: headerData)
        } catch {
            throw ChatPackageError.invalidHeader
        }
        guard header.packageVersion == packageVersion,
              header.transcriptSchemaVersion == ChatFormat.currentSchemaVersion else {
            throw ChatPackageError.unsupportedVersion
        }
        guard !header.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              header.turnCount > 0,
              header.artifactCount >= 0,
              header.files.count <= maximumEntries - 1 else {
            throw ChatPackageError.invalidHeader
        }
        let payloadPaths = Set(byPath.keys.filter { $0 != headerPath })
        let declaredPaths = Set(header.files.map(\.path))
        guard payloadPaths == declaredPaths,
              declaredPaths.count == header.files.count else {
            throw ChatPackageError.invalidHeader
        }
        for record in header.files {
            guard let body = byPath[record.path],
                  body.count == record.bytes,
                  sha256(body) == record.sha256 else {
                throw ChatPackageError.checksumMismatch
            }
        }
        guard let turns = byPath[turnsPath],
              header.hasContext == (byPath[contextPath] != nil) else {
            throw ChatPackageError.invalidHeader
        }
        var artifacts: [String: Data] = [:]
        for (path, body) in byPath where path.hasPrefix(artifactsPrefix) {
            let name = String(path.dropFirst(artifactsPrefix.count))
            guard !name.isEmpty,
                  !name.contains("/"),
                  try ArtifactStore.validatedFilename(name) == name,
                  artifacts[name.lowercased()] == nil else {
                throw ChatPackageError.invalidHeader
            }
            artifacts[name] = body
        }
        guard artifacts.count == header.artifactCount,
              payloadPaths.allSatisfy({ $0 == turnsPath || $0 == contextPath || $0.hasPrefix(artifactsPrefix) }) else {
            throw ChatPackageError.invalidHeader
        }
        let payload = ChatPackagePayload(
            header: header,
            turns: turns,
            context: byPath[contextPath],
            artifacts: artifacts
        )
        _ = try prepare(payload)
        return ChatImportProposal(sourceName: sourceName, payload: payload)
    }

    static func prepare(_ payload: ChatPackagePayload) throws -> PreparedChatPackage {
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
            throw ChatPackageError.invalidTranscript
        }
        let context: AgentContextCheckpoint?
        do {
            context = try payload.context.map { try decoder.decode(AgentContextCheckpoint.self, from: $0) }
        } catch {
            throw ChatPackageError.invalidContext
        }
        let prepared = try validate(turns: turns, context: context)
        guard prepared.turns.count == payload.header.turnCount,
              prepared.turns.requiresContextCheckpoint == payload.header.hasCompactedContext else {
            throw ChatPackageError.invalidHeader
        }
        let packaged = Set(payload.artifacts.keys.map { $0.lowercased() })
        for artifact in referencedArtifacts(turns: prepared.turns, context: prepared.context) {
            guard packaged.contains(artifact.fileName.lowercased()) else {
                throw ChatPackageError.missingArtifact(artifact.fileName)
            }
        }
        return PreparedChatPackage(
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
        guard !turns.isEmpty, ChatFormat.normalize(turns) == turns else {
            throw ChatPackageError.invalidTranscript
        }
        var document = ChatDocument(turns: turns)
        document.apply(.sealAllTurns)
        guard document.turns == turns else { throw ChatPackageError.invalidTranscript }
        let compacted = turns.requiresContextCheckpoint
        guard !compacted || context != nil else { throw ChatPackageError.incompleteCompaction }
        let retainedContext = compacted ? context : nil
        let boundary = retainedContext?.boundary(in: turns)
        guard retainedContext == nil || boundary != nil else { throw ChatPackageError.invalidContext }
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
        let referenced = referencedArtifacts(turns: turns, context: context)
        for artifact in referenced {
            let key = artifact.fileName.lowercased()
            guard !result.keys.contains(where: { $0.lowercased() == key }) else { continue }
            guard artifact.exists else { throw ChatPackageError.missingArtifact(artifact.fileName) }
            let data = try Data(contentsOf: artifact.fileURL, options: .mappedIfSafe)
            guard data.count <= maximumEntryBytes else { throw ChatPackageError.tooLarge }
            result[artifact.fileName] = data
        }
        return (result, referenced.first?.fileURL.deletingLastPathComponent())
    }

    private static func includingArtifactDependencies(_ direct: [String: Data], directory: URL?) throws -> [String: Data] {
        guard let directory else { return direct }
        let candidates = ArtifactStore.list(in: directory).filter { artifact in
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
                guard data.count <= maximumEntryBytes else { throw ChatPackageError.tooLarge }
                result[candidate.fileName] = data
                changed = true
            }
        }
        return result
    }

    private static func referencedArtifacts(turns: [Turn], context: AgentContextCheckpoint?) -> [Artifact] {
        var result: [Artifact] = []
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
            case .tooLarge: throw ChatPackageError.tooLarge
            case .invalidArchive: throw ChatPackageError.invalidArchive
            case .encrypted: throw ChatPackageError.encrypted
            case .unsupportedCompression: throw ChatPackageError.unsupportedCompression
            case .unsafePath: throw ChatPackageError.unsafePath
            case .checksumMismatch: throw ChatPackageError.checksumMismatch
            }
        }
    }
}

private nonisolated extension ContentBlock {
    var artifact: Artifact? {
        if case .attachment(let artifact) = self { return artifact }
        return nil
    }

    func replacingArtifacts(_ names: [String: String], directory: URL) -> ContentBlock {
        guard case .attachment(let artifact) = self,
              let name = names[artifact.fileName.lowercased()] else { return self }
        return .attachment(Artifact(fileName: name, directory: directory))
    }
}

private nonisolated extension Message {
    var artifacts: [Artifact] {
        switch self {
        case .user(let value): value.content.compactMap(\.artifact)
        case .assistant(let value): value.content.compactMap(\.artifact)
        case .toolResult(let value): value.content.compactMap(\.artifact)
        }
    }

    func replacingArtifacts(_ names: [String: String], directory: URL) -> Message {
        switch self {
        case .user(var value):
            value.content = value.content.map { $0.replacingArtifacts(names, directory: directory) }
            return .user(value)
        case .assistant(var value):
            value.content = value.content.map { $0.replacingArtifacts(names, directory: directory) }
            return .assistant(value)
        case .toolResult(var value):
            value.content = value.content.map { $0.replacingArtifacts(names, directory: directory) }
            return .toolResult(value)
        }
    }
}

@MainActor
@Observable
final class ChatImportCoordinator {
    private(set) var proposal: ChatImportProposal?
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var importedChatID: UUID?
    @ObservationIgnored private var operation: Task<Void, Never>?

    func receive(_ url: URL) {
        operation?.cancel()
        let request = UUID()
        isLoading = true
        isSaving = false
        proposal = nil
        errorMessage = nil
        importedChatID = nil
        operation = Task {
            do {
                let proposal = try await Task.detached(priority: .userInitiated) {
                    guard url.pathExtension.lowercased() == "chat" else { throw ChatPackageError.invalidArchive }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                       size > ChatPackageCodec.maximumPackageBytes {
                        throw ChatPackageError.tooLarge
                    }
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    return try ChatPackageCodec.decode(data, sourceName: url.lastPathComponent)
                }.value
                guard !Task.isCancelled else { return }
                self.proposal = proposal
                isLoading = false
                Log.ui.info("ChatImport.ready request=\(request) title=\(proposal.header.title) source=\(proposal.sourceName)")
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                isLoading = false
                errorMessage = error.localizedDescription
                Log.ui.error("ChatImport.open request=\(request) source=\(url.lastPathComponent) failed=\(error.localizedDescription)")
            }
        }
    }

    func install(using chats: ChatManager) {
        guard let proposal else { return }
        isSaving = true
        operation = Task {
            do {
                let chat = try await chats.importPackage(proposal.payload)
                guard !Task.isCancelled else { return }
                self.proposal = nil
                isSaving = false
                importedChatID = chat.id
                Log.ui.info("ChatImport.saved chat=\(chat.id) title=\(proposal.header.title)")
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                isSaving = false
                errorMessage = error.localizedDescription
                Log.ui.error("ChatImport.save title=\(proposal.header.title) failed=\(error.localizedDescription)")
            }
        }
    }

    func dismissProposal() {
        guard !isSaving else { return }
        proposal = nil
    }

    func dismissError() { errorMessage = nil }
    func consumeImportedChat() { importedChatID = nil }
}
