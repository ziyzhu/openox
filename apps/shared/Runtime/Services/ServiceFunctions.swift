import Foundation

extension Conversation: OxFunctionBridge {
    func websiteConversationAttachments(_ refs: [JSONValue]) async throws -> [WebsiteAttachment] {
        var attachments: [WebsiteAttachment] = []
        var total = 0
        for (index, ref) in refs.enumerated() {
            guard let fields = ref.objectValue, fields["id"]?.intValue == index,
                  let name = fields["name"]?.stringValue, let mimeType = fields["mimeType"]?.stringValue else {
                throw WebsiteProviderError("Invalid website attachment reference", kind: .unsupportedInput)
            }
            let stored = try await repository.file(named: name, in: scope)
            let file = try await repository.materializeFile(stored, in: scope)
            guard file.exists, file.mimeType == mimeType,
                  let size = file.size, size <= FileLimits.fileBytes else {
                throw WebsiteProviderError("Website attachment is unavailable, too large, or has a different MIME type", kind: .unsupportedInput)
            }
            let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: file.fileURL) }.value
            total += data.count
            guard !data.isEmpty, total <= FileLimits.fileBytes else {
                throw WebsiteProviderError("Website attachments exceed the upload limit", kind: .unsupportedInput)
            }
            attachments.append(WebsiteAttachment(name: name, mimeType: mimeType, data: data))
        }
        return attachments
    }

    public func validateService(domain: String, purpose: String) async throws -> JSONValue? {
        try await serviceOperations.validateService(domain: domain, purpose: purpose)
    }

    public func createService(kind: String, domain: String, name: String, endpoint: String?, transport: String?, faviconURL: JSONValue?, purpose: String) async throws -> JSONValue? {
        try await serviceOperations.createService(kind: kind, domain: domain, name: name, endpoint: endpoint, transport: transport, faviconURL: faviconURL, purpose: purpose)
    }

    public func updateService(domain: String, fields: [String: JSONValue], purpose: String) async throws -> JSONValue? {
        try await serviceOperations.updateService(domain: domain, fields: fields, purpose: purpose)
    }

    public func deleteService(domain: String, purpose: String) async throws -> JSONValue? {
        let result = try await serviceOperations.deleteService(domain: domain, purpose: purpose)
        if result?.objectValue?["kind"]?.stringValue == "mcp" {
            let deleted = result?.objectValue?["domain"]?.stringValue
            setAttachedServices(attachedServices.filter { $0.domain != deleted })
        }
        return result
    }

    public func connectRepository(origin: String, commit: String?, purpose: String) async throws -> JSONValue? {
        try await serviceOperations.connectRepository(origin: origin, commit: commit, purpose: purpose)
    }

    public func repositoryConflicts(service: String?, compare: Bool, purpose: String) async throws -> JSONValue? {
        try await serviceOperations.repositoryConflicts(service: service, compare: compare, purpose: purpose)
    }

    public func resolveRepositoryConflict(service: String, repository: String, purpose: String) async throws -> JSONValue? {
        try await serviceOperations.resolveRepositoryConflict(service: service, repository: repository, purpose: purpose)
    }

    public func enableRepository(repository: String, enabled: Bool, purpose: String) async throws -> JSONValue? {
        try await serviceOperations.enableRepository(repository: repository, enabled: enabled, purpose: purpose)
    }

    public func syncRepository(repository: String, purpose: String) async throws -> JSONValue? {
        try await serviceOperations.syncRepository(repository: repository, purpose: purpose)
    }

    public func disconnectRepository(repository: String, purpose: String) async throws -> JSONValue? {
        try await serviceOperations.disconnectRepository(repository: repository, purpose: purpose)
    }

    public func exportRepository(name: String, services: [String], skills: [String], purpose: String) async throws -> JSONValue? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let services = services.map { id in ["web:", "api:", "mcp:"].first(where: id.hasPrefix).map { String(id.dropFirst($0.count)) } ?? id }
        let args: JSONValue = .object([
            "name": .string(name),
            "services": .array(services.map(JSONValue.string)),
            "skills": .array(skills.map(JSONValue.string)),
        ])
        return try await tracked(Actions.repositoryExport, args, purpose: purpose) {
            guard !name.isEmpty, name.count <= 100, !(services.isEmpty && skills.isEmpty),
                  Set(services).count == services.count, Set(skills).count == skills.count else {
                throw RuntimeError.bridge("ox.repository.export: pass a name and at least one distinct Local service ID or skill name")
            }
            let export = try await self.serviceManager.exportLocalPackage(named: name, services: services, skills: skills)
            let archive = try ZipArchiveCodec.encode(export.files, maximumArchiveBytes: FileLimits.fileBytes)
            let file = try await self.repository.importFile(
                data: archive, suggestedName: "\(name).zip", in: self.scope, conversation: self.conversationReference
            )
            self.embedFile(file)
            guard let path = file.virtualPath.map({ String($0.drop(while: { $0 == "/" })) }) else {
                throw RuntimeError.bridge("ox.repository.export: the archive was written but its path is unavailable")
            }
            Log.session.info("bridge.repository.export services=\(export.services.count) skills=\(export.skills.count) files=\(export.files.count) bytes=\(archive.count)")
            return .object([
                "path": .string(path),
                "name": .string(export.name),
                "services": .array(export.services.map(JSONValue.string)),
                "skills": .array(export.skills.map(JSONValue.string)),
                "manifest": .string(export.manifest),
                "files": .array(export.files.map { .string($0.path) }),
                "bytes": .int(archive.count),
                "exported": .bool(true),
            ])
        }
    }

    public func attachService(domain: String, purpose: String) async throws -> JSONValue? {
        try await serviceOperations.attachService(domain: domain, purpose: purpose)
    }

    public func detachService(domain: String, purpose: String) async throws -> JSONValue? {
        try await serviceOperations.detachService(domain: domain, purpose: purpose)
    }

    public func listAttachedServices(purpose: String) async throws -> JSONValue? {
        try await serviceOperations.listAttachedServices(purpose: purpose)
    }

    public func listServices(kind: String?, purpose: String) async throws -> JSONValue? {
        try await serviceOperations.listServices(kind: kind, purpose: purpose)
    }

    public func inspectService(domain: String, cursor: String?, purpose: String) async throws -> JSONValue? {
        try await serviceOperations.inspectService(domain: domain, cursor: cursor, purpose: purpose)
    }

    public func invokeAction(name: String, args: JSONValue?, session: JSONValue? = nil, pageURL: String? = nil, frameID: String? = nil, purpose: String) async throws -> JSONValue? {
        try Task.checkCancellation()
        return try await serviceOperations.invokeAction(name: name, args: args ?? .object([:]), session: session, pageURL: pageURL, frameID: frameID, purpose: purpose) ?? .null
    }

    public func findServices(query: String, purpose: String) async throws -> JSONValue? {
        try await serviceOperations.findServices(query: query, purpose: purpose)
    }

    public func loginService(domain: String, purpose: String) async throws -> JSONValue? {
        try Task.checkCancellation()
        return try await serviceOperations.loginService(domain: domain, purpose: purpose)
    }
}
