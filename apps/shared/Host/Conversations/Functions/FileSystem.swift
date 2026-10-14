import Foundation

extension Conversation {
    var skillsMount: SkillsMount {
        SkillsMount(repository: repository, scope: scope, manager: serviceManager, session: skillSession)
    }

    private var servicesMount: ServicesMount {
        ServicesMount(manager: serviceManager)
    }

    func fileBackend(operation: String, path: String, arguments: JSONValue) async throws -> JSONValue {
        try requireFileBackendScope()
        if path == "tmp" || path.hasPrefix("tmp/") {
            return .object(["value": try await javaScriptOutputs.operation(operation, path: path)])
        }
        var path = path
        var parts = path.split(separator: "/").map(String.init)
        if parts.count == 3, parts[0] == "conversations", ["conversation.json", "turns.jsonl"].contains(parts[2]) {
            parts[0] = "history"
            if let id = Int(parts[1]), id >= 0, let profileID = scope.profileID {
                parts[1] = DurableConversationReference(profileID: profileID, conversationID: id).compatibilityID.description
            }
            path = parts.joined(separator: "/")
        }
        let value: JSONValue
        switch operation {
        case "info":
            let location = try await fileSystemLocation(path)
            try await authorizeFileAccess(location, operation: .list)
            if try await fileSystemIsDirectory(location) {
                _ = try await listFileBackend(path: path)
                value = .object(["path": .string(path), "name": .string(path.split(separator: "/").last.map(String.init) ?? path),
                    "kind": .string("directory"), "size": .int(0), "mtimeMs": .int(0)])
            } else {
                let parent = path.split(separator: "/").dropLast().joined(separator: "/")
                let listing = try await listFileBackend(path: parent.isEmpty ? "." : parent)
                guard listing.count <= 10_000 else { throw RuntimeError.bridge("Directory exceeds entry limit") }
                guard let item = listing.first(where: { $0.objectValue?["path"]?.stringValue == path }),
                      let fields = item.objectValue else {
                    return .object(["error": .object(["code": .string("not_found"), "message": .string("File not found")])])
                }
                value = .object(["path": .string(path), "name": fields["name"] ?? .string(path),
                    "kind": fields["type"] ?? .string("file"), "size": fields["size"] ?? .int(0), "mtimeMs": .int(0)])
            }
        case "list":
            let listing = try await listFileBackend(path: path)
            guard listing.count <= 10_000 else { throw RuntimeError.bridge("Directory exceeds entry limit") }
            value = .array(listing.map { item in
                let fields = item.objectValue ?? [:]
                return .object(["path": fields["path"] ?? .null, "name": fields["name"] ?? .null,
                    "kind": fields["type"] ?? .null, "size": fields["size"] == .null ? .int(0) : fields["size"] ?? .int(0), "mtimeMs": .int(0)])
            })
        case "read":
            value = try await readFileBackend(path: path)
        case "write":
            guard let content = arguments.objectValue?["content"]?.stringValue else { throw RuntimeError.bridge("Missing file content") }
            value = try await writeFileBackend(path: path, content: content, expected: arguments.objectValue?["expected"]?.stringValue)
        case "delete":
            value = try await deleteFileBackend(path: path)
        case "activate":
            let location = try await fileSystemLocation(path)
            guard case .skillFile(let name) = location else { throw RuntimeError.bridge("Invalid skill activation path") }
            let skill = try await skillsMount.activate(named: name)
            activateSkill(name: skill.name, path: skill.filePath, content: skill.content)
            value = .null
        default:
            throw RuntimeError.bridge("Unavailable filesystem backend operation")
        }
        try Task.checkCancellation()
        return .object(["value": value])
    }

    private func requireFileBackendScope() throws {
        try Task.checkCancellation()
        guard StorageRoot.currentScope == scope else { throw RuntimeError.bridge("Filesystem Profile scope is no longer active") }
    }

    private func listFileBackend(path: String) async throws -> [JSONValue] {
        let location = try await fileSystemLocation(path, defaultRoot: true)
        try Task.checkCancellation()
        try await self.authorizeFileAccess(location, operation: .list)
        try requireFileBackendScope()
        guard try await self.fileSystemIsDirectory(location) else { throw VirtualFileSystem.Error.notDirectory(location.path) }
        let items: [JSONValue]
        switch location {
        case .root:
            var rootItems = [
                fileSystemItem(path: "MEMORY.md", type: "file", size: UserMemory.shared.text.utf8.count),
                fileSystemItem(path: "SOUL.md", type: "file", size: Soul.shared.text.utf8.count),
                fileSystemItem(path: "artifacts", type: "directory", size: nil),
                fileSystemItem(path: "skills", type: "directory", size: nil),
                fileSystemItem(path: "services", type: "directory", size: nil),
                fileSystemItem(path: "history", type: "directory", size: nil),
            ]
            rootItems.append(fileSystemItem(path: "files", type: "directory", size: nil))
            rootItems.append(contentsOf: try await resourceFiles().entries().map {
                fileSystemItem(path: $0.path, type: $0.isDirectory ? "directory" : "file", size: $0.size)
            })
            items = rootItems
        case .artifacts:
            items = try await repository.artifacts(in: scope).map {
                fileSystemItem(path: "artifacts/\($0.fileName)", type: "file", size: $0.size)
            }
        case .resource(let path):
            items = try await resourceFiles().entries(under: path).map {
                fileSystemItem(path: $0.path, type: $0.isDirectory ? "directory" : "file", size: $0.size)
            }
        case .skills:
            items = try await skillsMount.entries().map {
                fileSystemItem(path: $0.directoryPath, type: "directory", size: nil)
            }
        case .skill(let name):
            let skill = try await skillsMount.entry(named: name)
            var skillItems = [fileSystemItem(path: skill.filePath, type: "file", size: skill.content.utf8.count)]
            for directory in ["references", "scripts"] where skill.resources.contains(where: { $0.name.hasPrefix(directory + "/") }) {
                skillItems.append(fileSystemItem(path: "\(skill.directoryPath)/\(directory)", type: "directory", size: nil))
            }
            items = skillItems
        case .skillDirectory(let name, let path), .skillResource(let name, let path):
            let skill = try await skillsMount.entry(named: name)
            let prefix = path + "/"
            let children = Set(skill.resources.filter { $0.name.hasPrefix(prefix) }.map { String($0.name.dropFirst(prefix.count).split(separator: "/")[0]) })
            items = children.map { child in
                let relative = prefix + child
                let resource = skill.resources.first { $0.name == relative }
                return fileSystemItem(path: "\(skill.directoryPath)/\(relative)", type: resource == nil ? "directory" : "file", size: resource?.content.utf8.count)
            }
        case .services:
            items = ServicesMount.Kind.allCases.map {
                fileSystemItem(path: "services/\($0.rawValue)", type: "directory", size: nil)
            }
        case .serviceKind(let kind):
            items = servicesMount.entries(kind: kind).map {
                fileSystemItem(path: $0.directoryPath, type: "directory", size: nil)
            }
        case .service(let kind, let domain):
            items = try await servicesMount.sourceEntries(kind: kind, domain: domain, path: []).map {
                fileSystemItem(
                    path: "services/\(kind.rawValue)/\(domain)/\($0.name)",
                    type: $0.isDirectory ? "directory" : "file",
                    size: $0.size
                )
            }
        case .serviceItem(let kind, let domain, let path):
            items = try await servicesMount.sourceEntries(kind: kind, domain: domain, path: path).map {
                fileSystemItem(
                    path: "services/\(kind.rawValue)/\(domain)/\((path + [$0.name]).joined(separator: "/"))",
                    type: $0.isDirectory ? "directory" : "file",
                    size: $0.size
                )
            }
        case .conversations:
            items = await fileSystemConversationSummaries().map {
                fileSystemItem(path: "history/\(ConversationID($0.id))", type: "directory", size: nil)
            }
        case .conversation(let id):
            let sizes = try await repository.virtualConversationFileSizes(
                id,
                in: scope,
                snapshot: conversationManager?.readableConversationState(id, in: scope)
            )
            items = [
                fileSystemItem(path: "history/\(id)/conversation.json", type: "file", size: sizes.metadata),
                fileSystemItem(path: "history/\(id)/turns.jsonl", type: "file", size: sizes.transcript),
            ]
        case .files:
            items = DeviceFolderStore.shared.grants(for: scope.profileID).map {
                fileSystemItem(path: "files/\($0.id)", type: "directory", size: nil)
            }
        case .deviceFolder, .deviceItem:
            items = try await self.listDeviceFiles(location)
        case .memory, .soul, .artifact, .skillFile, .conversationMetadata, .conversationTurns:
            throw VirtualFileSystem.Error.notDirectory(location.path)
        }
        let sorted = items.sorted { lhs, rhs in
            (lhs.objectValue?["path"]?.stringValue ?? "").localizedStandardCompare(
                rhs.objectValue?["path"]?.stringValue ?? ""
            ) == .orderedAscending
        }
        let limit = 10_000
        Log.session.info("bridge.fs.list path=\(location.path) count=\(min(sorted.count, limit)) total=\(sorted.count)")
        return sorted
    }

    private func virtualConversationMetadata(_ id: ConversationID) async throws -> Data {
        try await repository.virtualConversationMetadata(id, in: scope, snapshot: conversationManager?.readableConversationState(id, in: scope))
    }

    private func virtualConversationTranscript(_ id: ConversationID) async throws -> Data {
        try await repository.virtualConversationTranscript(id, in: scope, snapshot: conversationManager?.readableConversationState(id, in: scope))
    }

    private func fileSystemConversationSummaries() async -> [ConversationMeta] {
        let saved = await repository.conversationSummaries(in: scope)
        let loaded = conversationManager?.readableConversationSummaries(in: scope) ?? []
        return Array(Dictionary(saved.map { ($0.id, $0) } + loaded.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest }).values)
    }

    private func readFileBackend(path: String) async throws -> JSONValue {
        let root = path.split(separator: "/").first.map(String.init) ?? ""
        if let route = durableRoute, root == "artifacts" || !VirtualFileSystem.hostRoots.contains(root) || (!isTemporary && ["MEMORY.md", "SOUL.md"].contains(root)) {
            let record = try await route.session.runtime.command(.object(["action": .string("fileStat"), "path": .string(path), "byPath": .bool(true)]))
            if record.objectValue?["file"] != .null, record.objectValue?["file"] != nil {
                let media = try await fileSystemMedia(path: path)
                let result = try await Task.detached(priority: .userInitiated) {
                    try FileLibrary.read(data: media.data, kind: media.kind, options: .init())
                }.value
                let unsupported = media.kind == .image
                    ? try ModelPromptRenderer.shared.render(.imageReadGuidance, input: .object(["path": .string(path)])) : result.unsupported
                return fileSystemReadJSON(path: path, result: FileLibrary.Read(text: result.text, truncated: result.truncated, unsupported: unsupported))
            }
        }
        let location = try await fileSystemLocation(path)
        try Task.checkCancellation()
        try await self.authorizeFileAccess(location, operation: .read)
        let result = try await fileSystemRead(location)
        Log.session.info("bridge.fs.read path=\(location.path) text=\(result.text?.count ?? 0) truncated=\(result.truncated)")
        return fileSystemReadJSON(path: location.path, result: result)
    }

    public func attachFileSystem(path: String, purpose: String) async throws -> JSONValue? {
        let webRequest = path.lowercased().hasPrefix("http:") || path.lowercased().hasPrefix("https:")
            ? try WebFetchRequest(url: path) : nil
        let source: String
        if let webRequest { source = webRequest.url.absoluteString }
        else { source = path.hasPrefix("/") ? String(path.dropFirst()) : path }
        let args: JSONValue = .object(["path": .string(source)])
        return try await tracked(Actions.fsAttach, args, purpose: purpose) {
            let attachment: TransientAttachment
            if let webRequest {
                let (_, response) = try await fetchWebResource(webRequest)
                guard response.ok else { throw RuntimeError.bridge("ox.fs.attach: HTTP \(response.status)") }
                attachment = try await Task.detached(priority: .userInitiated) {
                    try WebAttachmentFactory.make(response: response, filename: nil)
                }.value
            } else {
                let media = try await self.fileSystemMedia(path: source)
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try WebAttachmentFactory.make(data: media.data, filename: media.filename, mimeType: media.mimeType)
                }.value
                attachment = TransientAttachment(kind: prepared.kind, mimeType: prepared.mimeType, displayName: prepared.displayName,
                    data: prepared.data, reference: media.reference)
            }
            try Task.checkCancellation()
            try appendTransientAttachment(attachment)
            Log.session.info("bridge.fs.attach path=\(LogPrivacy.text(source)) bytes=\(attachment.data.count) mimeType=\(attachment.mimeType)")
            return attachmentJSON(attachment)
        }
    }

    nonisolated struct FileSystemMedia: Sendable {
        let filename: String
        let mimeType: String
        let kind: FileItem.Kind
        let data: Data
        let reference: String?

        init(artifact: FileItem, data: Data, reference: String? = nil) {
            filename = artifact.displayName
            mimeType = artifact.mimeType
            kind = artifact.kind
            self.data = data
            self.reference = reference
        }
    }

    func fileSystemMedia(path: String) async throws -> FileSystemMedia {
        if let route = durableRoute {
            let result = try? await route.session.runtime.command(.object(["action": .string("fileStat"), "path": .string(path), "byPath": .bool(true)]))
            if let record = result?.objectValue?["file"]?.objectValue, record["hidden"]?.boolValue != true,
               let actual = record["path"]?.stringValue, let reference = record["reference"]?.stringValue {
                let artifact = FileItem(fileName: reference, directory: route.artifactScope?.root ?? scope.root, relativePath: actual)
                let data = try await route.session.runtime.readFile(.object(record))
                return FileSystemMedia(artifact: artifact, data: data, reference: reference)
            }
        }
        let location = try await fileSystemLocation(path)
        try await authorizeFileAccess(location, operation: .read)
        let media: FileSystemMedia
        switch location {
        case .artifact(let name):
            let artifact = try await repository.artifact(named: name, in: scope)
            let data = try await repository.readFileData(named: name, in: scope)
            media = FileSystemMedia(artifact: artifact, data: data)
        case .deviceItem:
            media = try await withDeviceFile(location, mode: .read) { url in
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else { throw VirtualFileSystem.Error.notFile(location.path) }
                if let size = values.fileSize, size > FileLimits.fileBytes {
                    throw FileError.fileTooLarge(bytes: size, limit: FileLimits.fileBytes)
                }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                let data = try file.read(upToCount: FileLimits.fileBytes + 1) ?? Data()
                let artifact = FileItem(fileName: url.lastPathComponent, directory: url.deletingLastPathComponent())
                return FileSystemMedia(artifact: artifact, data: data)
            }
        default:
            throw RuntimeError.bridge("Media requires an artifact or a file inside an attached Files folder: \(location.path)")
        }
        guard media.data.count <= FileLimits.fileBytes else {
            throw FileError.fileTooLarge(bytes: media.data.count, limit: FileLimits.fileBytes)
        }
        try Task.checkCancellation()
        guard StorageRoot.currentScope == scope else { throw RuntimeError.bridge("File media belongs to a stale Profile scope") }
        return media
    }

    private func writeFileBackend(path: String, content: String, expected: String?) async throws -> JSONValue {
        let location = try await fileSystemLocation(path)
        try Task.checkCancellation()
        try await self.requireWritableFileContext(location, action: Actions.fsWrite)
        try await self.authorizeFileAccess(location, operation: .write)
        let item = try await self.fileMutationCoordinator.perform(key: self.fileMutationKey(location)) {
            try Task.checkCancellation()
            if let expected, case .deviceItem = location {
                return try await self.writeFileSystem(location, content: content, expected: expected)
            }
            if let expected, try await self.fileSystemUTF8Text(location) != expected {
                throw OxFunctionError(code: "file_changed", message: "File changed after reading: \(path)", recovery: "Read the file again with ox.fs.read, then rebuild the edit from the current content.")
            }
            try Task.checkCancellation()
            return try await self.writeFileSystem(location, content: content)
        }
        Log.session.info("bridge.fs.write path=\(location.path) bytes=\(content.utf8.count)")
        return item
    }

    private func deleteFileBackend(path: String) async throws -> JSONValue {
        let location = try await fileSystemLocation(path)
        try Task.checkCancellation()
        try await self.requireWritableFileContext(location, action: Actions.fsDelete)
        try await self.authorizeFileAccess(location, operation: .delete)
        switch location {
        case .artifact(let name):
            _ = try await repository.deleteFile(named: name, in: scope)
        case .skill(let name), .skillFile(let name):
            try await skillsMount.delete(name: name)
            refreshUserSkills()
        case .skillResource(let name, let path):
            var skill = try await skillsMount.entry(named: name).skill
            guard skill.resources?.removeValue(forKey: path) != nil else { throw SkillError.missing(path) }
            _ = try await skillsMount.save(skill)
        case .serviceItem(let kind, let domain, let path):
            try await servicesMount.deleteSource(kind: kind, domain: domain, path: path)
        case .deviceItem:
            try await self.deleteDeviceFile(location)
        default:
            throw VirtualFileSystem.Error.unsupportedMutation(location.path)
        }
        Log.session.info("bridge.fs.delete path=\(location.path)")
        return .object(["path": .string(location.path), "deleted": .bool(true)])
    }

    private enum FileAccessOperation: String {
        case list
        case read
        case search
        case write
        case edit
        case delete

    }

    private func authorizeFileAccess(
        _ location: VirtualFileSystem.Location,
        operation: FileAccessOperation
    ) async throws {
        switch location.area {
        case .files:
            break
        case .deviceFolder(let id):
            _ = try DeviceFolderStore.shared.requireGrant(id, profileId: scope.profileID)
        case .root, .memory, .soul, .artifacts, .resources, .skills, .services, .conversations:
            return
        }
        try requireFileBackendScope()
        Log.session.info("Conversation.fileAccess profile=\(scope.profileID?.uuidString ?? "temporary") operation=\(operation.rawValue) path=\(location.path)")
    }

    func requireWritableFileAction(_ action: String, args: Any?) async throws {
        guard [Actions.fsWrite, Actions.fsEdit, Actions.fsDelete].contains(action),
              let path = (args as? [String: Any])?["path"] as? String else { return }
        let root = path.split(separator: "/").first.map(String.init) ?? ""
        if ["MEMORY.md", "SOUL.md", "skills", "services", "files"].contains(root) {
            try await requireWritableFileContext(fileSystemLocation(path), action: action)
        } else if !isTemporary || durableRoute?.artifactScope == nil {
            try requireProfileMutation(action)
        }
    }

    private func requireWritableFileContext(_ location: VirtualFileSystem.Location, action: String) async throws {
        switch location {
        case .skill(let name), .skillFile(let name), .skillResource(let name, _):
            try await skillsMount.requireWritable(name: name, path: location.path)
        case .resource, .skillDirectory:
            throw VirtualFileSystem.Error.unsupportedMutation(location.path)
        case .serviceItem:
            return
        case .services, .serviceKind, .service, .conversations, .conversation, .conversationMetadata, .conversationTurns:
            throw VirtualFileSystem.Error.unsupportedMutation(location.path)
        default:
            break
        }
        switch location.area {
        case .files, .deviceFolder:
            return
        case .root, .memory, .soul, .artifacts, .resources, .skills, .services, .conversations:
            try requireProfileMutation(action)
        }
    }

    private func fileSystemIsDirectory(_ location: VirtualFileSystem.Location) async throws -> Bool {
        switch location {
        case .resource(let path):
            return try await resourceFiles().isDirectory(path)
        case .skillResource(let name, let path):
            return try await skillsMount.entry(named: name).resources.contains { $0.name.hasPrefix(path + "/") }
        case .serviceItem(let kind, let domain, let path):
            return try await servicesMount.sourceIsDirectory(kind: kind, domain: domain, path: path)
        case .deviceItem:
            return try await withDeviceFile(location, mode: .read) { url in
                try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            }
        default:
            return location.isDirectory
        }
    }

    private func fileMutationKey(_ location: VirtualFileSystem.Location) -> String {
        let path = location.path.lowercased()
        if case .serviceItem = location { return "services:\(path)" }
        switch location.area {
        case .files, .deviceFolder:
            return "files:\(path)"
        case .root, .memory, .soul, .artifacts, .resources, .skills, .services, .conversations:
            return "profile:\(scope.root.standardizedFileURL.path.lowercased()):\(path)"
        }
    }

    private func deviceFileParts(_ location: VirtualFileSystem.Location) throws -> (String, [String]) {
        switch location {
        case .deviceFolder(let id): return (id, [])
        case .deviceItem(let id, let components): return (id, components)
        default: throw VirtualFileSystem.Error.invalidPath(location.path)
        }
    }

    private func withDeviceFile<T: Sendable>(
        _ location: VirtualFileSystem.Location,
        mode: DeviceFolderStore.AccessMode,
        _ body: @escaping @Sendable (URL) throws -> T
    ) async throws -> T {
        let (id, components) = try deviceFileParts(location)
        return try await DeviceFolderStore.shared.coordinate(
            grantID: id,
            relativePath: components,
            profileId: scope.profileID,
            mode: mode,
            body
        )
    }

    private func listDeviceFiles(_ location: VirtualFileSystem.Location) async throws -> [JSONValue] {
        try await withDeviceFile(location, mode: .read) { directory in
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isHiddenKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            return try urls.compactMap { url in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { return nil }
                let path = location.path + "/" + url.lastPathComponent
                if values.isDirectory == true { return self.fileSystemItem(path: path, type: "directory", size: nil) }
                if values.isRegularFile == true { return self.fileSystemItem(path: path, type: "file", size: values.fileSize) }
                return nil
            }
        }
    }

    private func deleteDeviceFile(_ location: VirtualFileSystem.Location) async throws {
        try await withDeviceFile(location, mode: .delete) { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            guard values.isRegularFile == true else { throw VirtualFileSystem.Error.unsupportedMutation(location.path) }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func fileSystemRead(_ location: VirtualFileSystem.Location) async throws -> FileLibrary.Read {
        try requireFileBackendScope()
        switch location {
        case .memory:
            return try fileSystemTextRead(UserMemory.shared.text)
        case .soul:
            return try fileSystemTextRead(Soul.shared.text)
        case .artifact(let name):
            let artifact = try await repository.artifact(named: name, in: scope)
            return try await Task.detached(priority: .userInitiated) {
                try FileLibrary.read(artifact, options: .init())
            }.value
        case .resource(let path):
            return try fileSystemTextRead(await resourceFiles().text(path))
        case .skillFile(let name):
            let skill = try await skillsMount.entry(named: name)
            return try fileSystemTextRead(skill.content)
        case .skillResource(let name, let referenceName):
            let reference = try await skillsMount.resource(skill: name, path: referenceName)
            return try fileSystemTextRead(reference.content)
        case .serviceItem(let kind, let domain, let path):
            return try fileSystemTextRead(
                try await servicesMount.sourceText(kind: kind, domain: domain, path: path)
            )
        case .conversationMetadata(let id):
            let data = try await virtualConversationMetadata(id)
            return try fileSystemTextRead(String(decoding: data, as: UTF8.self))
        case .conversationTurns(let id):
            let data = try await virtualConversationTranscript(id)
            return try fileSystemTextRead(String(decoding: data, as: UTF8.self))
        case .deviceItem:
            let media = try await fileSystemMedia(path: location.path)
            let result = try await Task.detached(priority: .userInitiated) {
                try FileLibrary.read(data: media.data, kind: media.kind, options: .init())
            }.value
            let unsupported: String?
            switch media.kind {
            case .image:
                unsupported = try ModelPromptRenderer.shared.render(.imageReadGuidance, input: .object(["path": .string(location.path)]))
            case .file:
                unsupported = ModelGuidance.text("file.conversion")
            default:
                unsupported = result.unsupported
            }
            return FileLibrary.Read(text: result.text, truncated: result.truncated, unsupported: unsupported)
        case .root, .artifacts, .skills, .skill, .skillDirectory, .services, .serviceKind, .service, .conversations, .conversation, .files, .deviceFolder:
            throw VirtualFileSystem.Error.notFile(location.path)
        }
    }

    private func fileSystemTextRead(_ text: String) throws -> FileLibrary.Read {
        try FileLibrary.read(data: Data(text.utf8), kind: .text, options: .init(maxBytes: FileLimits.fileBytes))
    }

    private func fileSystemUTF8Text(_ location: VirtualFileSystem.Location) async throws -> String {
        try requireFileBackendScope()
        switch location {
        case .memory:
            return UserMemory.shared.text
        case .soul:
            return Soul.shared.text
        case .artifact(let name):
            let artifact = try await repository.artifact(named: name, in: scope)
            guard artifact.exists else { throw FileError.missing(name) }
            let data = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: artifact.fileURL)
            }.value
            guard data.count <= FileLimits.textBytes else {
                throw FileError.textTooLarge(bytes: data.count, limit: FileLimits.textBytes)
            }
            guard let text = String(data: data, encoding: .utf8) else { throw FileError.textNotUTF8 }
            return text
        case .resource(let path):
            return try await resourceFiles().text(path)
        case .skillFile(let name):
            return try await skillsMount.entry(named: name).content
        case .skillResource(let name, let referenceName):
            return try await skillsMount.resource(skill: name, path: referenceName).content
        case .serviceItem(let kind, let domain, let path):
            return try await servicesMount.sourceText(kind: kind, domain: domain, path: path)
        case .conversationMetadata(let id):
            return String(decoding: try await virtualConversationMetadata(id), as: UTF8.self)
        case .conversationTurns(let id):
            return String(decoding: try await virtualConversationTranscript(id), as: UTF8.self)
        case .deviceItem:
            return try await withDeviceFile(location, mode: .read) { url in
                let data = try Data(contentsOf: url)
                guard data.count <= FileLimits.textBytes else {
                    throw FileError.textTooLarge(bytes: data.count, limit: FileLimits.textBytes)
                }
                guard let text = String(data: data, encoding: .utf8) else { throw FileError.textNotUTF8 }
                return text
            }
        case .root, .artifacts, .skills, .skill, .skillDirectory, .services, .serviceKind, .service, .conversations, .conversation, .files, .deviceFolder:
            throw VirtualFileSystem.Error.notFile(location.path)
        }
    }

    private func writeFileSystem(
        _ location: VirtualFileSystem.Location,
        content: String,
        expected: String? = nil
    ) async throws -> JSONValue {
        try requireFileBackendScope()
        let data = Data(content.utf8)
        guard data.count <= FileLimits.textBytes else {
            throw FileError.textTooLarge(bytes: data.count, limit: FileLimits.textBytes)
        }
        switch location {
        case .resource:
            throw VirtualFileSystem.Error.unsupportedMutation(location.path)
        case .memory:
            UserMemory.shared.text = content
            return fileSystemItem(path: location.path, type: "file", size: data.count)
        case .soul:
            Soul.shared.text = content
            return fileSystemItem(path: location.path, type: "file", size: data.count)
        case .artifact(let name):
            let artifact = try await repository.writeFile(data: data, named: name, in: scope)
            embedFile(artifact)
            return fileSystemItem(path: "artifacts/\(artifact.fileName)", type: "file", size: artifact.size ?? data.count)
        case .skillFile(let name):
            try await skillsMount.requireWritable(name: name, path: location.path)
            guard let skill = SkillFiles.parse(content, directoryName: name) else {
                throw RuntimeError.bridge("ox.fs.write: skills/\(name)/SKILL.md must contain valid skill frontmatter and non-empty instructions.")
            }
            var content = skill
            content.resources = try? await skillsMount.entry(named: name).skill.resources
            let saved = try await skillsMount.save(content)
            refreshUserSkills()
            embedSkill(saved)
            let serialized = SkillFiles.serialize(saved)
            return fileSystemItem(path: "skills/\(saved.name)/SKILL.md", type: "file", size: serialized.utf8.count)
        case .skillResource(let name, let path):
            guard SkillFiles.isResourcePath(path) else { throw SkillError.invalidPackage }
            var skill = try await skillsMount.entry(named: name).skill
            var resources = skill.resources ?? [:]
            resources[path] = content
            skill.resources = resources
            _ = try await skillsMount.save(skill)
            return fileSystemItem(path: location.path, type: "file", size: data.count)
        case .serviceItem(let kind, let domain, let path):
            try await servicesMount.writeSource(kind: kind, domain: domain, path: path, content: content)
            return fileSystemItem(path: location.path, type: "file", size: data.count)
        case .deviceItem:
            try await withDeviceFile(location, mode: .write) { url in
                let parent = url.deletingLastPathComponent()
                guard (try parent.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
                    throw VirtualFileSystem.Error.notDirectory(parent.lastPathComponent)
                }
                if let expected {
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    let current = try file.read(upToCount: FileLimits.textBytes + 1) ?? Data()
                    guard String(data: current, encoding: .utf8) == expected else {
                        throw OxFunctionError(code: "file_changed", message: "File changed after reading: \(location.path)", recovery: "Read the file again with ox.fs.read, then rebuild the edit from the current content.")
                    }
                }
                try Task.checkCancellation()
                try data.write(to: url, options: .atomic)
            }
            return fileSystemItem(path: location.path, type: "file", size: data.count)
        case .root, .artifacts, .skills, .skill, .skillDirectory, .services, .serviceKind, .service, .conversations, .conversation, .conversationMetadata, .conversationTurns, .files, .deviceFolder:
            throw VirtualFileSystem.Error.notFile(location.path)
        }
    }

    nonisolated private func fileSystemItem(path: String, type: String, size: Int?) -> JSONValue {
        .object([
            "path": .string(path),
            "name": .string(path.split(separator: "/").last.map(String.init) ?? path),
            "type": .string(type),
            "size": size.map(JSONValue.int) ?? .null,
        ])
    }

    private func fileSystemReadJSON(path: String, result: FileLibrary.Read) -> JSONValue {
        .object([
            "path": .string(path),
            "text": result.text.map(JSONValue.string) ?? .null,
            "truncated": .bool(result.truncated),
            "unsupported": result.unsupported.map(JSONValue.string) ?? .null,
        ])
    }

    func refreshUserSkills() {
        guard StorageRoot.currentScope?.profileID == scope.profileID else { return }
        Skills.shared.refresh()
    }
}
