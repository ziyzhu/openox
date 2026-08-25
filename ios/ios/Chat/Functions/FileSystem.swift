import Foundation

extension Chat {
    var skillsMount: SkillsMount {
        SkillsMount(repository: repository, scope: scope, services: attachedServices)
    }

    private var servicesMount: ServicesMount {
        ServicesMount(manager: serviceManager)
    }

    public func listFileSystem(path: String, options: JSONValue?, purpose: String) async throws -> JSONValue? {
        let location = try virtualMachine.fileSystem.location(path, defaultRoot: true)
        let args = fileSystemArgs(path: location.path, options: options)
        return try await tracked(.fsList, args, purpose: purpose) {
            try await self.authorizeFileAccess(location, operation: .list)
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
                    fileSystemItem(path: "chats", type: "directory", size: nil),
                ]
                if self.attachedServices.contains(where: { $0.domain == "ios:files" }) {
                    rootItems.append(fileSystemItem(path: "files", type: "directory", size: nil))
                }
                items = rootItems
            case .artifacts:
                items = await repository.artifacts(in: scope).map {
                    fileSystemItem(path: "artifacts/\($0.fileName)", type: "file", size: $0.size)
                }
            case .skills:
                items = await skillsMount.entries().map {
                    fileSystemItem(path: $0.directoryPath, type: "directory", size: nil)
                }
            case .skill(let name):
                let skill = try await skillsMount.entry(named: name)
                var skillItems = [fileSystemItem(path: skill.filePath, type: "file", size: skill.content.utf8.count)]
                if !skill.references.isEmpty {
                    skillItems.append(fileSystemItem(path: skill.referenceDirectoryPath, type: "directory", size: nil))
                }
                items = skillItems
            case .skillReferences(let name):
                let skill = try await skillsMount.entry(named: name)
                guard !skill.references.isEmpty else { throw VirtualFileSystem.Error.notDirectory(location.path) }
                items = skill.references.map {
                    fileSystemItem(path: skill.referencePath($0), type: "file", size: $0.content.utf8.count)
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
            case .chats:
                items = await repository.chatSummaries(in: scope).map {
                    fileSystemItem(path: "chats/\(ChatID($0.id))", type: "directory", size: nil)
                }
            case .chat(let id):
                _ = try await repository.virtualChatMetadata(id, in: scope)
                items = [
                    fileSystemItem(path: "chats/\(id)/chat.json", type: "file", size: nil),
                    fileSystemItem(path: "chats/\(id)/turns.jsonl", type: "file", size: nil),
                ]
            case .files:
                items = DeviceFolderStore.shared.grants.map {
                    fileSystemItem(path: "files/\($0.id)", type: "directory", size: nil)
                }
            case .deviceFolder, .deviceItem:
                items = try await self.listDeviceFiles(location)
            case .memory, .soul, .artifact, .skillFile, .skillReference, .chatMetadata, .chatTurns:
                throw VirtualFileSystem.Error.notDirectory(location.path)
            }
            let sorted = items.sorted { lhs, rhs in
                (lhs.objectValue?["path"]?.stringValue ?? "").localizedStandardCompare(
                    rhs.objectValue?["path"]?.stringValue ?? ""
                ) == .orderedAscending
            }
            let limit = fileSystemInt(options, key: "limit", default: 50, minimum: 1, maximum: 100)
            Log.session.info("bridge.fs.list path=\(location.path) count=\(min(sorted.count, limit)) total=\(sorted.count)")
            return .object([
                "items": .array(Array(sorted.prefix(limit))),
                "truncated": .bool(sorted.count > limit),
            ])
        }
    }

    public func readFileSystem(path: String, options: JSONValue?, purpose: String) async throws -> JSONValue? {
        let location = try virtualMachine.fileSystem.location(path)
        let args = fileSystemArgs(path: location.path, options: options)
        return try await tracked(.fsRead, args, purpose: purpose) {
            try await self.authorizeFileAccess(location, operation: .read)
            let result = try await fileSystemRead(location, options: options)
            Log.session.info("bridge.fs.read path=\(location.path) text=\(result.text?.count ?? 0) truncated=\(result.truncated)")
            return fileSystemReadJSON(path: location.path, result: result)
        }
    }

    public func writeFileSystem(path: String, content: String, purpose: String) async throws -> JSONValue? {
        let location = try virtualMachine.fileSystem.location(path)
        let args: JSONValue = .object(["path": .string(location.path), "bytes": .int(content.utf8.count)])
        return try await tracked(.fsWrite, args, purpose: purpose) {
            try await self.requireWritableFileContext(location, action: .fsWrite)
            try await self.authorizeFileAccess(location, operation: .write, args: args)
            let item = try await self.fileMutationCoordinator.perform(key: self.fileMutationKey(location)) {
                try await self.writeFileSystem(location, content: content)
            }
            Log.session.info("bridge.fs.write path=\(location.path) bytes=\(content.utf8.count)")
            return item
        }
    }

    public func editFileSystem(path: String, edits value: JSONValue?, purpose: String) async throws -> JSONValue? {
        let location = try virtualMachine.fileSystem.location(path)
        let edits = try fileSystemEdits(value)
        let args: JSONValue = .object([
            "path": .string(location.path),
            "edits": .array(edits.map { .object(["oldText": .string($0.oldText), "newText": .string($0.newText)]) }),
        ])
        return try await tracked(.fsEdit, args, purpose: purpose) {
            try await self.requireWritableFileContext(location, action: .fsEdit)
            try await self.authorizeFileAccess(location, operation: .edit, args: args)
            return try await self.fileMutationCoordinator.perform(key: self.fileMutationKey(location)) {
                let original = try await self.fileSystemUTF8Text(location)
                let content = try self.virtualMachine.fileSystem.apply(edits, to: original)
                let item = try await self.writeFileSystem(location, content: content)
                Log.session.info("bridge.fs.edit path=\(location.path) edits=\(edits.count) chars=\(original.count)->\(content.count)")
                return item
            }
        }
    }

    public func deleteFileSystem(path: String, purpose: String) async throws -> JSONValue? {
        let location = try virtualMachine.fileSystem.location(path)
        let args: JSONValue = .object(["path": .string(location.path)])
        return try await tracked(.fsDelete, args, purpose: purpose) {
            try await self.requireWritableFileContext(location, action: .fsDelete)
            try await self.authorizeFileAccess(location, operation: .delete, args: args)
            switch location {
            case .artifact(let name):
                try await requireApproval(action: InvocationName.fsDelete.rawValue, args: args.toAny())
                _ = try await repository.deleteArtifact(named: name, in: scope)
            case .skill(let name), .skillFile(let name):
                _ = try await repository.deleteSkill(named: name, in: scope)
                refreshUserSkills()
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
    }

    public func globFileSystem(
        pattern: String,
        path: String,
        options: JSONValue?,
        purpose: String
    ) async throws -> JSONValue? {
        let base = try virtualMachine.fileSystem.location(path, defaultRoot: true)
        let args = fileSystemSearchArgs(pattern: pattern, path: base.path, options: options)
        return try await tracked(.fsGlob, args, purpose: purpose) {
            try await self.authorizeFileAccess(base, operation: .search)
            guard try await self.fileSystemIsDirectory(base) else { throw VirtualFileSystem.Error.notDirectory(base.path) }
            let limit = fileSystemInt(options, key: "limit", default: 100, minimum: 1, maximum: 1_000)
            let candidates = try await fileSystemPaths(for: base)
            var matches: [String] = []
            for candidate in candidates {
                guard let relative = virtualMachine.fileSystem.relativePath(candidate, under: base),
                      try virtualMachine.fileSystem.matches(path: relative, pattern: pattern) else { continue }
                matches.append(candidate)
            }
            matches.sort { $0.localizedStandardCompare($1) == .orderedAscending }
            Log.session.info("bridge.fs.glob path=\(base.path) patternChars=\(pattern.count) hits=\(min(matches.count, limit)) total=\(matches.count)")
            return .object([
                "paths": .array(matches.prefix(limit).map(JSONValue.string)),
                "truncated": .bool(matches.count > limit),
            ])
        }
    }

    public func grepFileSystem(
        pattern: String,
        path: String,
        options: JSONValue?,
        purpose: String
    ) async throws -> JSONValue? {
        guard !pattern.isEmpty else { throw RuntimeError.bridge("ox.fs.grep: pattern cannot be empty.") }
        let base = try virtualMachine.fileSystem.location(path, defaultRoot: true)
        let args = fileSystemSearchArgs(pattern: pattern, path: base.path, options: options)
        return try await tracked(.fsGrep, args, purpose: purpose) {
            try await self.authorizeFileAccess(base, operation: .search)
            let values = options?.objectValue ?? [:]
            let literal = values["literal"]?.boolValue == true
            let expressionOptions: NSRegularExpression.Options = values["ignoreCase"]?.boolValue == true ? [.caseInsensitive] : []
            let expression: NSRegularExpression
            do {
                expression = try NSRegularExpression(
                    pattern: literal ? NSRegularExpression.escapedPattern(for: pattern) : pattern,
                    options: expressionOptions
                )
            } catch {
                throw RuntimeError.bridge("ox.fs.grep: invalid regular expression: \(error.localizedDescription)")
            }
            let glob = values["glob"]?.stringValue
            let contextLines = fileSystemInt(options, key: "contextLines", default: 0, minimum: 0, maximum: 5)
            let limit = fileSystemInt(options, key: "limit", default: 100, minimum: 1, maximum: 200)
            var allPaths = try await fileSystemPaths(for: base)
            if base == .root {
                allPaths.removeAll { $0.hasPrefix("chats/") }
            }
            let candidates: [String]
            if try await self.fileSystemIsDirectory(base) {
                candidates = try allPaths.filter { candidate in
                    guard let relative = virtualMachine.fileSystem.relativePath(candidate, under: base) else { return false }
                    return try glob.map { try virtualMachine.fileSystem.matches(path: relative, pattern: $0) } ?? true
                }
            } else {
                candidates = allPaths.contains(base.path) ? [base.path] : []
            }
            var matches: [JSONValue] = []
            var scannedFiles = 0
            var skippedFiles = 0
            var scannedBytes = 0
            var truncated = candidates.count > VirtualFileSystem.maximumSearchFiles
            let maximumSearchBytes = base.area == .chats
                ? VirtualFileSystem.maximumChatSearchBytes
                : VirtualFileSystem.maximumSearchBytes
            candidateLoop: for candidate in candidates.prefix(VirtualFileSystem.maximumSearchFiles) {
                guard let text = try await fileSystemSearchText(candidate) else {
                    skippedFiles += 1
                    continue
                }
                scannedFiles += 1
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                for index in lines.indices {
                    let line = lines[index]
                    let bytes = line.utf8.count + 1
                    if scannedBytes + bytes > maximumSearchBytes {
                        truncated = true
                        break candidateLoop
                    }
                    scannedBytes += bytes
                    let range = NSRange(line.startIndex..<line.endIndex, in: line)
                    guard let match = expression.firstMatch(in: line, range: range) else { continue }
                    let beforeStart = max(0, index - contextLines)
                    let afterEnd = min(lines.count, index + contextLines + 1)
                    matches.append(.object([
                        "path": .string(candidate),
                        "line": .int(index + 1),
                        "text": .string(fileSystemLine(line, match: match.range)),
                        "before": .array(lines[beforeStart..<index].map { .string(fileSystemLine($0)) }),
                        "after": .array(lines[(index + 1)..<afterEnd].map { .string(fileSystemLine($0)) }),
                    ]))
                    if matches.count >= limit {
                        truncated = true
                        break
                    }
                }
                if matches.count >= limit { break }
            }
            Log.session.info("bridge.fs.grep path=\(base.path) patternChars=\(pattern.count) scannedFiles=\(scannedFiles) scannedBytes=\(scannedBytes) skipped=\(skippedFiles) hits=\(matches.count) truncated=\(truncated)")
            return .object([
                "matches": .array(matches),
                "scannedFiles": .int(scannedFiles),
                "skippedFiles": .int(skippedFiles),
                "truncated": .bool(truncated),
            ])
        }
    }

    private struct FileSystemRead {
        let text: String?
        let truncated: Bool
        let unsupported: String?
    }

    private enum FileAccessOperation: String {
        case list
        case read
        case search
        case write
        case edit
        case delete

        var approvalInvocation: InvocationName? {
            switch self {
            case .write: .fsWrite
            case .edit: .fsEdit
            case .delete: .fsDelete
            case .list, .read, .search: nil
            }
        }
    }

    private func authorizeFileAccess(
        _ location: VirtualFileSystem.Location,
        operation: FileAccessOperation,
        args: JSONValue? = nil
    ) async throws {
        switch location.area {
        case .files:
            break
        case .deviceFolder(let id):
            guard DeviceFolderStore.shared.grant(id) != nil else { throw DeviceFolderStore.StoreError.missingGrant(id) }
        case .root, .memory, .soul, .artifacts, .skills, .services, .chats:
            return
        }
        try requireIOSService("ios:files")
        Log.session.info("Chat.fileAccess service=ios:files operation=\(operation.rawValue) path=\(location.path)")
        guard let action = operation.approvalInvocation else { return }
        try await requireApproval(
            action: Self.fileApproveKey(action),
            args: args?.toAny(),
            prompt: "\(action.approvalLabel)\n\(location.path)"
        )
    }

    private func requireWritableFileContext(_ location: VirtualFileSystem.Location, action: InvocationName) async throws {
        switch location {
        case .skill(let name), .skillFile(let name):
            try await skillsMount.requireWritable(name: name, path: location.path)
        case .skillReferences, .skillReference:
            throw VirtualFileSystem.Error.unsupportedMutation(location.path)
        case .serviceItem:
            return
        case .services, .serviceKind, .service, .chats, .chat, .chatMetadata, .chatTurns:
            throw VirtualFileSystem.Error.unsupportedMutation(location.path)
        default:
            break
        }
        switch location.area {
        case .files, .deviceFolder:
            return
        case .root, .memory, .soul, .artifacts, .skills, .services, .chats:
            try requireProfileMutation(action)
        }
    }

    private func fileSystemIsDirectory(_ location: VirtualFileSystem.Location) async throws -> Bool {
        switch location {
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
        case .root, .memory, .soul, .artifacts, .skills, .services, .chats:
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

    private func fileSystemRead(_ location: VirtualFileSystem.Location, options: JSONValue?) async throws -> FileSystemRead {
        let maxBytes = fileSystemInt(
            options,
            key: "maxBytes",
            default: 20_000,
            minimum: 1,
            maximum: VirtualFileSystem.maximumReadBytes
        )
        switch location {
        case .memory:
            return fileSystemBoundedRead(UserMemory.shared.text, maxBytes: maxBytes)
        case .soul:
            return fileSystemBoundedRead(Soul.shared.text, maxBytes: maxBytes)
        case .artifact(let name):
            let artifact = try await repository.artifact(named: name, in: scope)
            let readOptions = ArtifactLibrary.readOptions(from: options)
            let result = try await Task.detached(priority: .userInitiated) {
                try ArtifactLibrary.read(artifact, options: readOptions)
            }.value
            return FileSystemRead(text: result.text, truncated: result.truncated, unsupported: result.unsupported)
        case .skillFile(let name):
            let skill = try await skillsMount.entry(named: name)
            let result = fileSystemBoundedRead(skill.content, maxBytes: maxBytes)
            if let content = result.text {
                activateSkill(name: skill.name, path: skill.filePath, content: content)
            }
            return result
        case .skillReference(let name, let referenceName):
            let reference = try await skillsMount.reference(skill: name, named: referenceName)
            return fileSystemBoundedRead(reference.content, maxBytes: maxBytes)
        case .serviceItem(let kind, let domain, let path):
            return fileSystemBoundedRead(
                try await servicesMount.sourceText(kind: kind, domain: domain, path: path),
                maxBytes: maxBytes
            )
        case .chatMetadata(let id):
            let data = try await repository.virtualChatMetadata(id, in: scope)
            return fileSystemBoundedRead(String(decoding: data, as: UTF8.self), maxBytes: maxBytes)
        case .chatTurns(let id):
            let data = try await repository.virtualChatTranscript(id, in: scope)
            return fileSystemBoundedRead(String(decoding: data, as: UTF8.self), maxBytes: maxBytes)
        case .deviceItem:
            let readOptions = ArtifactLibrary.readOptions(from: options)
            let result = try await withDeviceFile(location, mode: .read) { url in
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { throw VirtualFileSystem.Error.notFile(location.path) }
                let artifact = Artifact(fileName: url.lastPathComponent, directory: url.deletingLastPathComponent())
                return try ArtifactLibrary.read(artifact, options: readOptions)
            }
            return FileSystemRead(text: result.text, truncated: result.truncated, unsupported: result.unsupported)
        case .root, .artifacts, .skills, .skill, .skillReferences, .services, .serviceKind, .service, .chats, .chat, .files, .deviceFolder:
            throw VirtualFileSystem.Error.notFile(location.path)
        }
    }

    private func fileSystemBoundedRead(_ text: String, maxBytes: Int) -> FileSystemRead {
        let data = Data(text.utf8)
        guard data.count > maxBytes else {
            return FileSystemRead(text: text, truncated: false, unsupported: nil)
        }
        return FileSystemRead(
            text: String(decoding: data.prefix(maxBytes), as: UTF8.self),
            truncated: true,
            unsupported: nil
        )
    }

    private func fileSystemUTF8Text(_ location: VirtualFileSystem.Location) async throws -> String {
        switch location {
        case .memory:
            return UserMemory.shared.text
        case .soul:
            return Soul.shared.text
        case .artifact(let name):
            let artifact = try await repository.artifact(named: name, in: scope)
            guard artifact.exists else { throw ArtifactError.missing(name) }
            let data = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: artifact.fileURL)
            }.value
            guard data.count <= ArtifactLimits.textBytes else {
                throw ArtifactError.textTooLarge(bytes: data.count, limit: ArtifactLimits.textBytes)
            }
            guard let text = String(data: data, encoding: .utf8) else { throw ArtifactError.textNotUTF8 }
            return text
        case .skillFile(let name):
            return try await skillsMount.entry(named: name).content
        case .skillReference(let name, let referenceName):
            return try await skillsMount.reference(skill: name, named: referenceName).content
        case .serviceItem(let kind, let domain, let path):
            return try await servicesMount.sourceText(kind: kind, domain: domain, path: path)
        case .chatMetadata(let id):
            return String(decoding: try await repository.virtualChatMetadata(id, in: scope), as: UTF8.self)
        case .chatTurns(let id):
            return String(decoding: try await repository.virtualChatTranscript(id, in: scope), as: UTF8.self)
        case .deviceItem:
            return try await withDeviceFile(location, mode: .read) { url in
                let data = try Data(contentsOf: url)
                guard data.count <= ArtifactLimits.textBytes else {
                    throw ArtifactError.textTooLarge(bytes: data.count, limit: ArtifactLimits.textBytes)
                }
                guard let text = String(data: data, encoding: .utf8) else { throw ArtifactError.textNotUTF8 }
                return text
            }
        case .root, .artifacts, .skills, .skill, .skillReferences, .services, .serviceKind, .service, .chats, .chat, .files, .deviceFolder:
            throw VirtualFileSystem.Error.notFile(location.path)
        }
    }

    private func writeFileSystem(
        _ location: VirtualFileSystem.Location,
        content: String
    ) async throws -> JSONValue {
        let data = Data(content.utf8)
        guard data.count <= ArtifactLimits.textBytes else {
            throw ArtifactError.textTooLarge(bytes: data.count, limit: ArtifactLimits.textBytes)
        }
        switch location {
        case .memory:
            UserMemory.shared.text = content
            return fileSystemItem(path: location.path, type: "file", size: data.count)
        case .soul:
            Soul.shared.text = content
            return fileSystemItem(path: location.path, type: "file", size: data.count)
        case .artifact(let name):
            let artifact = try await repository.writeArtifact(data: data, named: name, in: scope)
            embedArtifact(artifact)
            return fileSystemItem(path: "artifacts/\(artifact.fileName)", type: "file", size: artifact.size ?? data.count)
        case .skillFile(let name):
            try await skillsMount.requireWritable(name: name, path: location.path)
            guard let skill = SkillFiles.parse(content, directoryName: name) else {
                throw RuntimeError.bridge("ox.fs.write: skills/\(name)/SKILL.md must contain valid skill frontmatter and non-empty instructions.")
            }
            let replacing = (try? await repository.skill(named: name, in: scope)) == nil ? nil : name
            let saved = try await repository.saveSkill(
                name: skill.name,
                description: skill.description,
                instructions: skill.instructions,
                services: skill.services,
                replacing: replacing,
                in: scope
            )
            refreshUserSkills()
            embedSkill(saved)
            let serialized = SkillFiles.serialize(saved)
            return fileSystemItem(path: "skills/\(saved.name)/SKILL.md", type: "file", size: serialized.utf8.count)
        case .serviceItem(let kind, let domain, let path):
            try await servicesMount.writeSource(kind: kind, domain: domain, path: path, content: content)
            return fileSystemItem(path: location.path, type: "file", size: data.count)
        case .deviceItem:
            try await withDeviceFile(location, mode: .write) { url in
                let parent = url.deletingLastPathComponent()
                guard (try parent.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
                    throw VirtualFileSystem.Error.notDirectory(parent.lastPathComponent)
                }
                try data.write(to: url, options: .atomic)
            }
            return fileSystemItem(path: location.path, type: "file", size: data.count)
        case .root, .artifacts, .skills, .skill, .skillReferences, .skillReference, .services, .serviceKind, .service, .chats, .chat, .chatMetadata, .chatTurns, .files, .deviceFolder:
            throw VirtualFileSystem.Error.notFile(location.path)
        }
    }

    private func fileSystemPaths(for base: VirtualFileSystem.Location) async throws -> [String] {
        switch base {
        case .services:
            var paths: [String] = []
            for service in servicesMount.entries() {
                paths.append(contentsOf: try await servicesMount.sourcePaths(kind: service.kind, domain: service.domain))
                if paths.count >= VirtualFileSystem.maximumSearchFiles { break }
            }
            return Array(paths.prefix(VirtualFileSystem.maximumSearchFiles))
        case .serviceKind(let kind):
            var paths: [String] = []
            for service in servicesMount.entries(kind: kind) {
                paths.append(contentsOf: try await servicesMount.sourcePaths(kind: kind, domain: service.domain))
                if paths.count >= VirtualFileSystem.maximumSearchFiles { break }
            }
            return Array(paths.prefix(VirtualFileSystem.maximumSearchFiles))
        case .service(let kind, let domain):
            return try await servicesMount.sourcePaths(kind: kind, domain: domain)
        case .serviceItem(let kind, let domain, _):
            let paths = try await servicesMount.sourcePaths(kind: kind, domain: domain)
            if try await fileSystemIsDirectory(base) {
                let prefix = base.path + "/"
                return paths.filter { $0.hasPrefix(prefix) }
            }
            return [base.path]
        case .chat(let id):
            _ = try await repository.virtualChatMetadata(id, in: scope)
            return ["chats/\(id)/chat.json", "chats/\(id)/turns.jsonl"]
        case .chatMetadata, .chatTurns:
            return [base.path]
        case .skill(let name):
            let skill = try await skillsMount.entry(named: name)
            return [skill.filePath] + skill.references.map(skill.referencePath)
        case .skillFile:
            return [base.path]
        case .skillReferences(let name):
            let skill = try await skillsMount.entry(named: name)
            return skill.references.map(skill.referencePath)
        case .skillReference:
            return [base.path]
        default:
            break
        }
        switch base.area {
        case .files:
            var paths: [String] = []
            for grant in DeviceFolderStore.shared.grants {
                paths.append(contentsOf: try await deviceFilePaths(.deviceFolder(grant.id)))
                if paths.count >= VirtualFileSystem.maximumSearchFiles { break }
            }
            return Array(paths.prefix(VirtualFileSystem.maximumSearchFiles)).sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
        case .deviceFolder:
            return try await deviceFilePaths(base)
        case .chats:
            return await chatFileSystemPaths()
        case .root, .memory, .soul, .artifacts, .skills, .services:
            break
        }
        let artifacts = await repository.artifacts(in: scope).map { "artifacts/\($0.fileName)" }
        let skills = await skillsMount.entries().flatMap { skill in
            [skill.filePath] + skill.references.map(skill.referencePath)
        }
        var services: [String] = []
        for service in servicesMount.entries() {
            services.append(contentsOf: try await servicesMount.sourcePaths(kind: service.kind, domain: service.domain))
            if services.count >= VirtualFileSystem.maximumSearchFiles { break }
        }
        let chats = await chatFileSystemPaths()
        return (["MEMORY.md", "SOUL.md"] + artifacts + skills + services + chats).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private func chatFileSystemPaths() async -> [String] {
        await repository.chatSummaries(in: scope).flatMap { summary -> [String] in
            let directory = "chats/\(ChatID(summary.id))"
            return ["\(directory)/chat.json", "\(directory)/turns.jsonl"]
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func deviceFilePaths(_ base: VirtualFileSystem.Location) async throws -> [String] {
        try await withDeviceFile(base, mode: .read) { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isRegularFile == true { return [base.path] }
            guard values.isDirectory == true else { return [] }
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }
            var paths: [String] = []
            for case let item as URL in enumerator {
                let itemValues = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard itemValues.isSymbolicLink != true, itemValues.isRegularFile == true else { continue }
                let relative = item.path.replacingOccurrences(of: url.path + "/", with: "", options: [.anchored])
                paths.append(base.path + "/" + relative)
                if paths.count >= VirtualFileSystem.maximumSearchFiles { break }
            }
            return paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    private func fileSystemSearchText(_ path: String) async throws -> String? {
        let location = try virtualMachine.fileSystem.location(path)
        switch location {
        case .memory:
            return UserMemory.shared.text
        case .soul:
            return Soul.shared.text
        case .skillFile(let name):
            return try await skillsMount.entry(named: name).content
        case .skillReference(let name, let referenceName):
            return try await skillsMount.reference(skill: name, named: referenceName).content
        case .serviceItem(let kind, let domain, let path):
            return try await servicesMount.sourceText(kind: kind, domain: domain, path: path)
        case .chatMetadata(let id):
            return String(decoding: try await repository.virtualChatMetadata(id, in: scope), as: UTF8.self)
        case .chatTurns(let id):
            return String(decoding: try await repository.virtualChatTranscript(id, in: scope), as: UTF8.self)
        case .artifact(let name):
            let artifact = try await repository.artifact(named: name, in: scope)
            guard artifact.exists, artifact.kind == .text || artifact.kind == .html else { return nil }
            let data = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: artifact.fileURL)
            }.value
            guard data.count <= ArtifactLimits.textBytes else { return nil }
            return String(data: data, encoding: .utf8)
        case .deviceItem:
            return try await withDeviceFile(location, mode: .read) { url in
                let artifact = Artifact(fileName: url.lastPathComponent, directory: url.deletingLastPathComponent())
                guard artifact.exists, artifact.kind == .text || artifact.kind == .html else { return nil }
                let data = try Data(contentsOf: url)
                guard data.count <= ArtifactLimits.textBytes else { return nil }
                return String(data: data, encoding: .utf8)
            }
        case .root, .artifacts, .skills, .skill, .skillReferences, .services, .serviceKind, .service, .chats, .chat, .files, .deviceFolder:
            return nil
        }
    }

    private func fileSystemEdits(_ value: JSONValue?) throws -> [VirtualFileSystem.Edit] {
        guard let values = value?.arrayValue, !values.isEmpty else { throw VirtualFileSystem.Error.emptyEdits }
        return try values.map { value in
            guard let fields = value.objectValue,
                  let oldText = fields["oldText"]?.stringValue,
                  let newText = fields["newText"]?.stringValue else {
                throw RuntimeError.bridge("ox.fs.edit: each edit requires string oldText and newText fields.")
            }
            return VirtualFileSystem.Edit(oldText: oldText, newText: newText)
        }
    }

    private func fileSystemArgs(path: String, options: JSONValue?) -> JSONValue {
        var fields: [String: JSONValue] = ["path": .string(path)]
        if let options, options != .null { fields["options"] = options }
        return .object(fields)
    }

    private func fileSystemSearchArgs(pattern: String, path: String, options: JSONValue?) -> JSONValue {
        var fields: [String: JSONValue] = ["pattern": .string(pattern), "path": .string(path)]
        if let options, options != .null { fields["options"] = options }
        return .object(fields)
    }

    nonisolated private func fileSystemItem(path: String, type: String, size: Int?) -> JSONValue {
        .object([
            "path": .string(path),
            "name": .string(path.split(separator: "/").last.map(String.init) ?? path),
            "type": .string(type),
            "size": size.map(JSONValue.int) ?? .null,
        ])
    }

    private func fileSystemReadJSON(path: String, result: FileSystemRead) -> JSONValue {
        .object([
            "path": .string(path),
            "text": result.text.map(JSONValue.string) ?? .null,
            "truncated": .bool(result.truncated),
            "unsupported": result.unsupported.map(JSONValue.string) ?? .null,
        ])
    }

    private func fileSystemInt(
        _ options: JSONValue?,
        key: String,
        default defaultValue: Int,
        minimum: Int,
        maximum: Int
    ) -> Int {
        let value = options?.objectValue?[key]?.intValue ?? defaultValue
        return max(minimum, min(maximum, value))
    }

    private func fileSystemLine(_ text: String, match: NSRange? = nil) -> String {
        guard text.count > VirtualFileSystem.maximumLineCharacters else { return text }
        guard let match, let range = Range(match, in: text) else {
            return String(text.prefix(VirtualFileSystem.maximumLineCharacters - 1)) + "…"
        }
        let count = text.count
        let matchStart = text.distance(from: text.startIndex, to: range.lowerBound)
        let matchLength = text.distance(from: range.lowerBound, to: range.upperBound)
        let bodyLimit = VirtualFileSystem.maximumLineCharacters - 2
        let leadingContext = max(0, (bodyLimit - min(matchLength, bodyLimit)) / 2)
        var startOffset = max(0, matchStart - leadingContext)
        startOffset = min(startOffset, max(0, count - bodyLimit))
        let hasLeadingEllipsis = startOffset > 0
        let preliminaryEnd = min(count, startOffset + bodyLimit)
        let hasTrailingEllipsis = preliminaryEnd < count
        let contentLimit = VirtualFileSystem.maximumLineCharacters
            - (hasLeadingEllipsis ? 1 : 0)
            - (hasTrailingEllipsis ? 1 : 0)
        let start = text.index(text.startIndex, offsetBy: startOffset)
        let body = String(text[start...].prefix(contentLimit))
        return (hasLeadingEllipsis ? "…" : "") + body + (hasTrailingEllipsis ? "…" : "")
    }

    func refreshUserSkills() {
        guard StorageRoot.currentScope?.profileID == scope.profileID else { return }
        Skills.shared.refresh()
    }
}
