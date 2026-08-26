import Foundation

nonisolated private enum ProfileRepositoryError: LocalizedError {
    case staleScope(UUID?, URL)
    case unsupportedChatSchema(Int)
    case missingChat(ChatID)

    var errorDescription: String? {
        switch self {
        case .staleScope(let id, let root):
            "Profile scope is stale: id=\(id?.uuidString ?? "nil") root=\(root.path)"
        case .unsupportedChatSchema(let version):
            "Unsupported chat schema: \(version)"
        case .missingChat(let id):
            "Chat not found: \(id)"
        }
    }
}

actor ProfileRepository {
    static let shared = ProfileRepository()

    private struct WriteState {
        var turns: [Turn]
        var fileSize: UInt64
        var requiresCanonicalRewrite: Bool
    }

    private struct DecodedTranscript {
        let turns: [Turn]
        let fileSize: UInt64
        let needsNormalization: Bool
        let skipped: Int

        var requiresCanonicalRewrite: Bool { needsNormalization || skipped > 0 }
    }

    private enum WriteOperation: String {
        case unchanged
        case append
        case rewrite
    }

    private struct Export: Encodable {
        let metadata: ChatMeta
        let turns: [Turn]
    }

    private var writeCache: [ProfileScope: [ChatID: WriteState]] = [:]
    private var deleted: [ProfileScope: Set<ChatID>] = [:]
    private var artifactRenames: [ProfileScope: [String: String]] = [:]
    private static let newline: UInt8 = 0x0A

    #if targetEnvironment(simulator)
    nonisolated let debugSaveGate: ProfileRepositorySaveGate

    private init(debugSaveGate: ProfileRepositorySaveGate = ProfileRepositorySaveGate()) {
        self.debugSaveGate = debugSaveGate
    }
    #else
    private init() {}
    #endif

    nonisolated static func localDocuments() -> URL {
        let manager = FileManager.default
        return (try? manager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? manager.temporaryDirectory
    }

    nonisolated static func cloudDocuments() async -> URL? {
        #if targetEnvironment(simulator)
        guard !SimEnv.iCloudDisabled else { return nil }
        #endif
        guard let container = await Task.detached(priority: .userInitiated, operation: {
            FileManager.default.url(forUbiquityContainerIdentifier: AppConfiguration.iCloudContainerIdentifier)
        }).value else { return nil }
        return container.appendingPathComponent("Documents", isDirectory: true)
    }

    func createProfile(name: String, location: Profile.Location, base: URL) throws -> Profile {
        let folder = base.appendingPathComponent(Self.cleanName(name), isDirectory: true)
        return try createProfile(at: folder, location: location)
    }

    func createUniqueProfile(name: String, location: Profile.Location, base: URL) throws -> Profile {
        let folder = uniqueFolder(base: base, name: name)
        let stem = Self.cleanName(name)
        if folder.lastPathComponent != stem {
            Log.app.info("ProfileRepository.create name-conflict requested=\(stem) resolved=\(folder.lastPathComponent) location=\(location.rawValue)")
        }
        return try createProfile(at: folder, location: location)
    }

    private func createProfile(at folder: URL, location: Profile.Location) throws -> Profile {
        let manager = FileManager.default
        let name = folder.lastPathComponent
        let config = ProfileConfig.fresh()
        guard !manager.fileExists(atPath: folder.path) else {
            Log.app.info("ProfileRepository.create conflict=\(name) kind=\(nameConflictKind(at: folder)) location=\(location.rawValue)")
            throw ProfileError.nameExists(name)
        }
        let staging = try FileStaging.createDirectory(in: manager.temporaryDirectory, prefix: "profile-create")
        defer { FileStaging.cleanup(staging, operation: "profile-create") }
        do {
            try ProfileIO.writeConfig(config, to: staging)
            guard ProfileIO.readConfig(at: staging)?.id == config.id else {
                throw CocoaError(.fileReadCorruptFile)
            }
            switch location {
            case .local:
                try manager.moveItem(at: staging, to: folder)
            case .iCloud:
                try manager.setUbiquitous(true, itemAt: staging, destinationURL: folder)
            case .external:
                throw CocoaError(.featureUnsupported)
            }
            if location == .local { excludeFromBackup(folder) }
            Log.app.info("ProfileRepository.create name=\(folder.lastPathComponent) location=\(location.rawValue)")
            return Profile(
                id: config.id,
                name: folder.lastPathComponent,
                location: location,
                url: folder,
                createdAt: config.createdAt,
                version: config.version
            )
        } catch {
            if let installed = ProfileIO.profile(at: folder, location: location),
               installed.id == config.id {
                Log.app.info("ProfileRepository.create name=\(folder.lastPathComponent) location=\(location.rawValue) recovered-after-error")
                return installed
            }
            if manager.fileExists(atPath: folder.path) {
                Log.app.info("ProfileRepository.create conflict=\(name) kind=\(nameConflictKind(at: folder)) location=\(location.rawValue)")
                throw ProfileError.nameExists(name)
            }
            Log.app.error("ProfileRepository.create name=\(name) location=\(location.rawValue) failed: \(error.localizedDescription)")
            throw error
        }
    }

    func renameProfile(_ profile: Profile, to name: String, base: URL) throws -> Profile? {
        let stem = Self.cleanName(name)
        let destination = base.appendingPathComponent(stem, isDirectory: true)
        guard destination != profile.url, destination.lastPathComponent != profile.name else { return nil }
        if FileManager.default.fileExists(atPath: destination.path) && !sameFolder(destination, profile.url) {
            Log.app.info("ProfileRepository.rename id=\(profile.id) conflict=\(stem) kind=\(nameConflictKind(at: destination))")
            throw ProfileError.nameExists(stem)
        }
        try moveFolder(profile.url, to: destination, coordinated: profile.location == .iCloud)
        var renamed = profile
        renamed.name = destination.lastPathComponent
        renamed.url = destination
        Log.app.info("ProfileRepository.rename id=\(profile.id) -> \(destination.lastPathComponent)")
        return renamed
    }

    func moveProfile(_ profile: Profile, to location: Profile.Location, base: URL) throws -> Profile {
        let destination = uniqueFolder(base: base, name: profile.name)
        switch location {
        case .iCloud:
            try FileManager.default.setUbiquitous(true, itemAt: profile.url, destinationURL: destination)
        case .local:
            try FileManager.default.setUbiquitous(false, itemAt: profile.url, destinationURL: destination)
            excludeFromBackup(destination)
        case .external:
            throw CocoaError(.featureUnsupported)
        }
        var moved = profile
        moved.location = location
        moved.url = destination
        Log.app.info("ProfileRepository.move id=\(profile.id) -> \(location.rawValue)")
        return moved
    }

    func deleteProfile(_ profile: Profile) throws {
        try removeFolder(profile.url, coordinated: profile.location == .iCloud)
        writeCache = writeCache.filter { $0.key.profileID != profile.id }
        deleted = deleted.filter { $0.key.profileID != profile.id }
        artifactRenames = artifactRenames.filter { $0.key.profileID != profile.id }
        Log.app.info("ProfileRepository.delete id=\(profile.id) name=\(profile.name)")
    }

    func ensureLayout(in scope: ProfileScope) {
        _ = try? directory(named: "chats", in: scope)
        _ = try? artifactsDirectory(in: scope)
        _ = try? skillsDirectory(in: scope)
    }

    func startDownloads(in scope: ProfileScope) {
        let chats = chatDirectory(in: scope)
        guard let items = FileManager.default.enumerator(at: chats, includingPropertiesForKeys: nil) else { return }
        for case let item as URL in items {
            try? FileManager.default.startDownloadingUbiquitousItem(at: item)
        }
    }

    nonisolated static func cleanName(_ name: String) -> String {
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "/:"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Default" : cleaned
    }

    private func excludeFromBackup(_ url: URL) {
        do {
            try AppStoragePaths.excludeFromBackup(url)
            Log.app.info("ProfileRepository.backup path=\(url.lastPathComponent) excluded=true")
        } catch {
            Log.app.error("ProfileRepository.backup path=\(url.lastPathComponent) failed=\(error.localizedDescription)")
        }
    }

    func artifactsDirectory(in scope: ProfileScope) throws -> URL {
        try directory(named: "artifacts", in: scope)
    }

    func skillsDirectory(in scope: ProfileScope) throws -> URL {
        try directory(named: "skills", in: scope)
    }

    func file(named name: String, in scope: ProfileScope) throws -> URL {
        try requireProfile(in: scope)
        return scope.root.appendingPathComponent(name, isDirectory: false)
    }

    func readTextFile(named name: String, in scope: ProfileScope) throws -> String? {
        let url = try file(named: name, in: scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func writeTextFile(_ text: String, named name: String, in scope: ProfileScope) throws {
        try Data(text.utf8).write(to: file(named: name, in: scope), options: .atomic)
    }

    private func directory(named name: String, in scope: ProfileScope) throws -> URL {
        try requireProfile(in: scope)
        let directory = scope.root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func requireProfile(in scope: ProfileScope) throws {
        guard let id = scope.profileID,
              ProfileIO.readConfig(at: scope.root)?.id == id else {
            Log.app.warning("ProfileRepository.staleScope id=\(scope.profileID?.uuidString ?? "nil") root=\(scope.root.path)")
            throw ProfileRepositoryError.staleScope(scope.profileID, scope.root)
        }
    }

    private func uniqueFolder(base: URL, name: String) -> URL {
        let stem = Self.cleanName(name)
        let manager = FileManager.default
        var candidate = base.appendingPathComponent(stem, isDirectory: true)
        var suffix = 2
        while manager.fileExists(atPath: candidate.path) {
            candidate = base.appendingPathComponent("\(stem) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private func nameConflictKind(at url: URL) -> String {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return "missing" }
        guard isDirectory.boolValue else { return "item" }
        let config = url.appendingPathComponent(ProfileIO.configName, isDirectory: false)
        guard manager.fileExists(atPath: config.path) else { return "incomplete-folder" }
        return ProfileIO.readConfig(at: url) == nil ? "unreadable-profile" : "profile"
    }

    private func sameFolder(_ first: URL, _ second: URL) -> Bool {
        first.standardizedFileURL.path.compare(
            second.standardizedFileURL.path,
            options: [.caseInsensitive]
        ) == .orderedSame
    }

    private func moveFolder(_ source: URL, to destination: URL, coordinated: Bool) throws {
        let manager = FileManager.default
        guard coordinated else {
            try manager.moveItem(at: source, to: destination)
            return
        }
        var coordinationError: NSError?
        var moveError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: source,
            options: .forMoving,
            writingItemAt: destination,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedSource, coordinatedDestination in
            do {
                try manager.moveItem(at: coordinatedSource, to: coordinatedDestination)
            } catch {
                moveError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let moveError { throw moveError }
    }

    private func removeFolder(_ url: URL, coordinated: Bool) throws {
        let manager = FileManager.default
        guard coordinated else {
            try manager.removeItem(at: url)
            return
        }
        var coordinationError: NSError?
        var removeError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: url,
            options: .forDeleting,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try manager.removeItem(at: coordinatedURL)
            } catch {
                removeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let removeError { throw removeError }
    }

    func chatSummaries(in scope: ProfileScope) -> [ChatMeta] {
        do {
            try ensureChatDirectory(in: scope)
            let directories = try FileManager.default
                .contentsOfDirectory(at: chatDirectory(in: scope), includingPropertiesForKeys: [.isDirectoryKey])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            var unsupportedByVersion: [Int: Int] = [:]
            let summaries: [ChatMeta] = directories.compactMap { directory in
                do {
                    return try canonicalMetadata(in: directory, scope: scope)
                } catch ProfileRepositoryError.unsupportedChatSchema(let version) {
                    unsupportedByVersion[version, default: 0] += 1
                    Log.session.debug("ProfileRepository.chatSummaries unsupported-schema id=\(directory.lastPathComponent) version=\(version)")
                    return nil
                } catch {
                    Log.session.error("ProfileRepository.chatSummaries skipped=\(directory.lastPathComponent) error=\(error.localizedDescription)")
                    return nil
                }
            }
            if !unsupportedByVersion.isEmpty {
                let total = unsupportedByVersion.values.reduce(0, +)
                let breakdown = unsupportedByVersion
                    .sorted { $0.key < $1.key }
                    .map { "v\($0.key)=\($0.value)" }
                    .joined(separator: ",")
                Log.session.warning("ProfileRepository.chatSummaries unsupported-schema skipped=\(total) [\(breakdown)] current=\(ChatFormat.currentSchemaVersion)")
            }
            return summaries
        } catch {
            Log.session.error("ProfileRepository.chatSummaries failed=\(error.localizedDescription)")
            return []
        }
    }

    func virtualChatMetadata(_ id: ChatID, in scope: ProfileScope) throws -> Data {
        try virtualChatData(id, in: scope, file: .metadata)
    }

    func virtualChatTranscript(_ id: ChatID, in scope: ProfileScope) throws -> Data {
        try virtualChatData(id, in: scope, file: .transcript)
    }

    func loadChat(_ id: ChatID, in scope: ProfileScope) -> ChatLoadResult? {
        guard deleted[scope]?.contains(id) != true else { return nil }
        do {
            try ensureChatDirectory(in: scope)
            let result = try decodeState(id, in: scope)
            writeCache[scope, default: [:]][id] = WriteState(
                turns: result.load.state.turns,
                fileSize: result.fileSize,
                requiresCanonicalRewrite: result.requiresCanonicalRewrite
            )
            Log.session.info("ProfileRepository.loadChat chat=\(id) turns=\(result.load.state.turns.count) context=\(result.load.state.context != nil) needsPersistence=\(result.load.needsPersistence)")
            return result.load
        } catch {
            Log.session.error("ProfileRepository.loadChat chat=\(id) failed=\(error.localizedDescription)")
            return nil
        }
    }

    func saveChat(_ request: ChatSaveRequest, in scope: ProfileScope) -> ChatSaveReceipt {
        #if targetEnvironment(simulator)
        debugSaveGate.pass()
        #endif
        guard deleted[scope]?.contains(request.chatID) != true else {
            return ChatSaveReceipt(saveID: request.saveID, succeeded: false)
        }
        do {
            try ensureChatDirectory(request.chatID, in: scope)
            switch request.payload {
            case .metadata(let meta):
                try validate(meta)
                try encoder().encode(meta).write(to: metaURL(request.chatID, in: scope), options: .atomic)
                Log.session.info("ProfileRepository.saveChat chat=\(request.chatID) save=\(request.saveID) operation=metadata")
            case .chat(let state):
                let canonical = applyingArtifactRenames(to: state, in: scope)
                try validate(canonical.meta)
                let operation = try write(canonical.turns, id: request.chatID, in: scope)
                try write(canonical.context, id: request.chatID, in: scope)
                try encoder().encode(canonical.meta).write(to: metaURL(request.chatID, in: scope), options: .atomic)
                Log.session.info("ProfileRepository.saveChat chat=\(request.chatID) save=\(request.saveID) operation=\(operation.rawValue) turns=\(canonical.turns.count) context=\(canonical.context != nil)")
            }
            return ChatSaveReceipt(saveID: request.saveID, succeeded: true)
        } catch {
            writeCache[scope]?[request.chatID] = nil
            Log.session.error("ProfileRepository.saveChat chat=\(request.chatID) save=\(request.saveID) failed=\(error.localizedDescription)")
            return ChatSaveReceipt(saveID: request.saveID, succeeded: false)
        }
    }

    func export(_ state: ChatState) throws -> Data {
        try encoder().encode(Export(metadata: state.meta, turns: state.turns))
    }

    func importChatPackage(_ payload: ChatPackagePayload, in scope: ProfileScope) throws -> ChatState {
        try requireProfile(in: scope)
        try ensureChatDirectory(in: scope)
        let artifactDirectory = try artifactsDirectory(in: scope)
        let prepared = try ChatPackageCodec.prepare(payload)
        var reserved = Set<String>()
        var names: [String: String] = [:]

        func availableName(_ source: String) -> String {
            let url = URL(fileURLWithPath: source)
            let ext = url.pathExtension
            let stem = url.deletingPathExtension().lastPathComponent
            var candidate = source
            var suffix = 2
            while ArtifactStore.existingFilename(matching: candidate, in: artifactDirectory) != nil
                || reserved.contains(candidate.lowercased()) {
                candidate = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
                suffix += 1
            }
            reserved.insert(candidate.lowercased())
            return candidate
        }

        for source in prepared.artifacts.keys.sorted(by: {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }) {
            names[source.lowercased()] = availableName(source)
        }
        let materialized = try prepared.materialized(artifactNames: names, directory: artifactDirectory)
        let id = ChatID(UUID())
        let document = ChatDocument(turns: materialized.turns)
        let metadata = ChatMeta(
            id: id.rawValue,
            createdAt: payload.header.createdAt,
            lastActivity: Date(),
            title: String(payload.header.title.prefix(60)),
            isFavorite: false,
            modelID: nil,
            clientID: nil,
            monoRepositoryHash: nil,
            attachedServiceDomains: [],
            preview: document.preview
        )
        try validate(metadata)
        let state = ChatState(meta: metadata, turns: materialized.turns, context: materialized.context)
        let manager = FileManager.default
        let staging = try FileStaging.createDirectory(in: scope.root, prefix: "chat-import")
        let stagedArtifacts = staging.appendingPathComponent("artifacts", isDirectory: true)
        let stagedChat = staging.appendingPathComponent("chat", isDirectory: true)
        try manager.createDirectory(at: stagedArtifacts, withIntermediateDirectories: true)
        try manager.createDirectory(at: stagedChat, withIntermediateDirectories: true)
        defer { FileStaging.cleanup(staging, operation: "chat-import") }

        for (name, data) in materialized.artifacts {
            try data.write(to: stagedArtifacts.appendingPathComponent(name, isDirectory: false), options: .atomic)
        }
        try encoder().encode(metadata).write(
            to: stagedChat.appendingPathComponent("chat.json", isDirectory: false),
            options: .atomic
        )
        try blob(materialized.turns[...]).write(
            to: stagedChat.appendingPathComponent("turns.jsonl", isDirectory: false),
            options: .atomic
        )
        if let context = materialized.context {
            try encoder().encode(context).write(
                to: stagedChat.appendingPathComponent("context.json", isDirectory: false),
                options: .atomic
            )
        }

        var installedArtifacts: [URL] = []
        let destinationChat = chatURL(id, in: scope)
        do {
            for name in materialized.artifacts.keys.sorted() {
                let source = stagedArtifacts.appendingPathComponent(name, isDirectory: false)
                let destination = artifactDirectory.appendingPathComponent(name, isDirectory: false)
                try manager.moveItem(at: source, to: destination)
                installedArtifacts.append(destination)
            }
            try manager.moveItem(at: stagedChat, to: destinationChat)
        } catch {
            try? manager.removeItem(at: destinationChat)
            for artifact in installedArtifacts { try? manager.removeItem(at: artifact) }
            throw error
        }
        writeCache[scope, default: [:]][id] = WriteState(
            turns: materialized.turns,
            fileSize: fileSize(turnsURL(id, in: scope)),
            requiresCanonicalRewrite: false
        )
        Log.session.info("ProfileRepository.importChat chat=\(id) turns=\(materialized.turns.count) artifacts=\(materialized.artifacts.count) context=\(materialized.context != nil)")
        return state
    }

    func deleteChat(_ id: ChatID, in scope: ProfileScope) {
        deleted[scope, default: []].insert(id)
        writeCache[scope]?[id] = nil
        try? FileManager.default.removeItem(at: chatURL(id, in: scope))
        Log.session.info("ProfileRepository.deleteChat chat=\(id)")
    }

    private func write(_ turns: [Turn], id: ChatID, in scope: ProfileScope) throws -> WriteOperation {
        let url = turnsURL(id, in: scope)
        let currentSize = fileSize(url)
        var prior = writeCache[scope]?[id]
        let transcriptExists = FileManager.default.fileExists(atPath: url.path)
        if prior.map({ $0.fileSize != currentSize }) ?? transcriptExists {
            let decoded = try decodeTranscript(id, in: scope)
            prior = WriteState(
                turns: decoded.turns,
                fileSize: decoded.fileSize,
                requiresCanonicalRewrite: decoded.requiresCanonicalRewrite
            )
        }
        let existing = prior ?? WriteState(turns: [], fileSize: 0, requiresCanonicalRewrite: false)
        let firstDiff = firstDifference(existing.turns, turns)
        let operation: WriteOperation
        if existing.requiresCanonicalRewrite {
            try rewrite(turns, from: 0, at: url)
            operation = .rewrite
        } else if let firstDiff {
            if FileManager.default.fileExists(atPath: url.path),
               firstDiff == existing.turns.count,
               turns.count > existing.turns.count {
                try append(turns[firstDiff...], to: url)
                operation = .append
            } else {
                try rewrite(turns, from: firstDiff, at: url)
                operation = .rewrite
            }
        } else {
            operation = .unchanged
        }
        writeCache[scope, default: [:]][id] = WriteState(
            turns: turns,
            fileSize: fileSize(url),
            requiresCanonicalRewrite: false
        )
        return operation
    }

    func renameArtifact(named oldName: String, to newName: String, in scope: ProfileScope) throws -> Artifact {
        let directory = try artifactsDirectory(in: scope)
        let renamed = try ArtifactStore.rename(oldName, to: newName, directory: directory)
        do {
            try rewriteArtifactReferences(from: oldName, to: renamed.fileName, in: scope)
        } catch {
            _ = try? ArtifactStore.rename(renamed.fileName, to: oldName, directory: directory)
            throw error
        }
        var aliases = artifactRenames[scope] ?? [:]
        let redirected = aliases.compactMap { key, value in
            value.caseInsensitiveCompare(oldName) == .orderedSame ? key : nil
        }
        for key in redirected { aliases[key] = renamed.fileName }
        aliases[oldName.lowercased()] = renamed.fileName
        artifactRenames[scope] = aliases
        if var cached = writeCache[scope] {
            for (id, state) in cached {
                cached[id]?.turns = state.turns.map {
                    $0.replacingArtifact(named: oldName, with: renamed.fileName, directory: directory)
                }
            }
            writeCache[scope] = cached
        }
        Log.session.info("ProfileRepository.renameArtifact from=\(oldName) to=\(renamed.fileName)")
        return renamed
    }

    private func rewriteArtifactReferences(from oldName: String, to newName: String, in scope: ProfileScope) throws {
        try ensureChatDirectory(in: scope)
        let directory = try artifactsDirectory(in: scope)
        let files = try FileManager.default.contentsOfDirectory(
            at: chatDirectory(in: scope),
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.map {
            $0.appendingPathComponent("turns.jsonl", isDirectory: false)
        }.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        let decoder = decoder(scope: scope)
        let encoder = encoder()
        for file in files {
            let lines = try transcriptLines(file)
            var output = Data()
            var changed = false
            for line in lines {
                if let turn = try? decoder.decode(Turn.self, from: line) {
                    let updated = turn.replacingArtifact(named: oldName, with: newName, directory: directory)
                    if updated != turn {
                        output.append(try encoder.encode(updated))
                        output.append(Self.newline)
                        changed = true
                        continue
                    }
                }
                output.append(line)
            }
            if changed { try output.write(to: file, options: .atomic) }
        }
    }

    private func applyingArtifactRenames(to state: ChatState, in scope: ProfileScope) -> ChatState {
        guard let aliases = artifactRenames[scope], !aliases.isEmpty,
              let directory = try? artifactsDirectory(in: scope) else { return state }
        let turns = state.turns.map { turn in
            aliases.reduce(turn) { current, alias in
                current.replacingArtifact(named: alias.key, with: alias.value, directory: directory)
            }
        }
        return ChatState(
            meta: state.meta,
            turns: turns,
            context: turns == state.turns ? state.context : nil
        )
    }

    private func decodeState(_ id: ChatID, in scope: ProfileScope) throws -> (
        load: ChatLoadResult,
        fileSize: UInt64,
        requiresCanonicalRewrite: Bool
    ) {
        let storedMeta = try canonicalMetadata(in: chatURL(id, in: scope), scope: scope)
        let transcript = try decodeTranscript(id, in: scope)
        let decoder = decoder(scope: scope)
        let checkpointURL = contextURL(id, in: scope)
        let context: AgentContextCheckpoint?
        var invalidContext = false
        if FileManager.default.fileExists(atPath: checkpointURL.path) {
            do {
                context = try decoder.decode(AgentContextCheckpoint.self, from: Data(contentsOf: checkpointURL))
            } catch {
                context = nil
                invalidContext = true
                Log.session.error("ProfileRepository.decodeChat chat=\(id) invalid-context error=\(error.localizedDescription)")
            }
        } else {
            context = nil
        }
        let needsPersistence = transcript.needsNormalization || invalidContext
        return (
            ChatLoadResult(
                state: ChatState(meta: storedMeta, turns: transcript.turns, context: context),
                needsPersistence: needsPersistence
            ),
            transcript.fileSize,
            needsPersistence || transcript.skipped > 0
        )
    }

    private enum VirtualChatFile {
        case metadata
        case transcript
    }

    private func virtualChatData(_ id: ChatID, in scope: ProfileScope, file: VirtualChatFile) throws -> Data {
        try requireProfile(in: scope)
        guard deleted[scope]?.contains(id) != true else { throw ProfileRepositoryError.missingChat(id) }
        _ = try canonicalMetadata(in: chatURL(id, in: scope), scope: scope)
        let url = switch file {
        case .metadata: metaURL(id, in: scope)
        case .transcript: turnsURL(id, in: scope)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw ProfileRepositoryError.missingChat(id) }
        let data = try Data(contentsOf: url)
        Log.session.info("ProfileRepository.virtualChatRead chat=\(id) file=\(url.lastPathComponent) bytes=\(data.count)")
        return data
    }

    private func decodeTranscript(_ id: ChatID, in scope: ProfileScope) throws -> DecodedTranscript {
        let url = turnsURL(id, in: scope)
        let lines = FileManager.default.fileExists(atPath: url.path) ? try transcriptLines(url) : []
        let decoder = decoder(scope: scope)
        var decoded: [Turn] = []
        var skipped = 0
        for line in lines {
            do {
                decoded.append(try decoder.decode(Turn.self, from: line))
            } catch {
                skipped += 1
                Log.session.error("ProfileRepository.decodeChat chat=\(id) skipped-turn error=\(error.localizedDescription)")
            }
        }
        let turns = ChatFormat.normalize(decoded)
        return DecodedTranscript(
            turns: turns,
            fileSize: fileSize(url),
            needsNormalization: turns != decoded,
            skipped: skipped
        )
    }

    private func validate(_ meta: ChatMeta) throws {
        guard meta.schemaVersion == ChatFormat.currentSchemaVersion else {
            Log.session.error("ProfileRepository.validate unsupported-schema chat=\(meta.id) version=\(meta.schemaVersion)")
            throw CocoaError(.fileWriteInvalidFileName)
        }
    }

    private func canonicalMetadata(in directory: URL, scope: ProfileScope) throws -> ChatMeta {
        let metadataURL = directory.appendingPathComponent("chat.json", isDirectory: false)
        let meta = try decoder(scope: scope).decode(ChatMeta.self, from: Data(contentsOf: metadataURL))
        guard meta.schemaVersion == ChatFormat.currentSchemaVersion else {
            throw ProfileRepositoryError.unsupportedChatSchema(meta.schemaVersion)
        }
        return meta
    }

    private func firstDifference(_ stored: [Turn], _ candidate: [Turn]) -> Int? {
        for index in 0..<min(stored.count, candidate.count) where stored[index] != candidate[index] {
            return index
        }
        return stored.count == candidate.count ? nil : min(stored.count, candidate.count)
    }

    private func append(_ turns: ArraySlice<Turn>, to url: URL) throws {
        let data = try blob(turns)
        guard !data.isEmpty else { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func rewrite(_ turns: [Turn], from firstDiff: Int, at url: URL) throws {
        let lines = FileManager.default.fileExists(atPath: url.path) ? try transcriptLines(url) : []
        let boundary = min(firstDiff, lines.count, turns.count)
        var output = lines.prefix(boundary).reduce(into: Data()) { $0.append($1) }
        output.append(try blob(turns[boundary...]))
        try output.write(to: url, options: .atomic)
    }

    private func ensureChatDirectory(in scope: ProfileScope) throws {
        try requireProfile(in: scope)
        try FileManager.default.createDirectory(at: chatDirectory(in: scope), withIntermediateDirectories: true)
    }

    private func ensureChatDirectory(_ id: ChatID, in scope: ProfileScope) throws {
        try ensureChatDirectory(in: scope)
        try FileManager.default.createDirectory(at: chatURL(id, in: scope), withIntermediateDirectories: true)
    }

    nonisolated private func chatDirectory(in scope: ProfileScope) -> URL {
        scope.root.appendingPathComponent("chats", isDirectory: true)
    }

    private func chatURL(_ id: ChatID, in scope: ProfileScope) -> URL {
        chatDirectory(in: scope).appendingPathComponent(id.rawValue.uuidString, isDirectory: true)
    }

    private func metaURL(_ id: ChatID, in scope: ProfileScope) -> URL {
        chatURL(id, in: scope).appendingPathComponent("chat.json", isDirectory: false)
    }

    private func turnsURL(_ id: ChatID, in scope: ProfileScope) -> URL {
        chatURL(id, in: scope).appendingPathComponent("turns.jsonl", isDirectory: false)
    }

    private func contextURL(_ id: ChatID, in scope: ProfileScope) -> URL {
        chatURL(id, in: scope).appendingPathComponent("context.json", isDirectory: false)
    }

    private func write(_ context: AgentContextCheckpoint?, id: ChatID, in scope: ProfileScope) throws {
        let url = contextURL(id, in: scope)
        guard let context else {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        try encoder().encode(context).write(to: url, options: .atomic)
    }

    private func encoder() -> JSONEncoder {
        JSONEncoder()
    }

    private func decoder(scope: ProfileScope) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.userInfo[.profileScope] = scope
        return decoder
    }

    private func transcriptLines(_ url: URL) throws -> [Data] {
        try [UInt8](Data(contentsOf: url)).split(separator: Self.newline).map { line in
            var data = Data(line)
            data.append(Self.newline)
            return data
        }
    }

    private func blob(_ turns: ArraySlice<Turn>) throws -> Data {
        let encoder = encoder()
        return try turns.reduce(into: Data()) { output, turn in
            output.append(try encoder.encode(turn))
            output.append(Self.newline)
        }
    }

    private func fileSize(_ url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
