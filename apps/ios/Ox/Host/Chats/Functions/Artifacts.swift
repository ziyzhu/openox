import Foundation

extension Chat {
    public func attachArtifact(filename: String, purpose: String) async throws -> JSONValue? {
        let args: JSONValue = .object(["source": .string("artifact"), "filename": .string(filename)])
        return try await tracked(.artifactAttach, args, purpose: purpose) {
            let artifact = try await repository.artifact(named: filename, in: scope)
            let attachment = try WebAttachmentFactory.make(artifact: artifact)
            try appendTransientAttachment(attachment)
            return attachmentJSON(attachment)
        }
    }

    public func importWebArtifact(url: String, filename: String?, purpose: String) async throws -> JSONValue? {
        let request = try WebFetchRequest(url: url)
        let args: JSONValue = .object([
            "url": .string(request.url.absoluteString),
            "filename": filename.map(JSONValue.string) ?? .null,
        ])
        return try await tracked(.artifactImport, args, purpose: purpose) {
            try requireProfileMutation(.artifactImport)
            try await requireApproval(action: InvocationName.artifactImport.rawValue, args: args.toAny())
            let (_, response) = try await fetchWebResource(request)
            let suggestedName = filename ?? response.suggestedFilename
            let artifact = try await ArtifactImporter.importDataAsync(
                response.data,
                suggestedName: suggestedName,
                in: scope
            )
            Log.session.info("bridge.artifact.import filename=\(artifact.fileName) bytes=\(response.data.count)")
            return try Self.encodeToJSON(ArtifactLibrary.Item(artifact))
        }
    }

    public func renameArtifact(filename: String, newFilename: String, purpose: String) async throws -> JSONValue? {
        let args: JSONValue = .object(["filename": .string(filename), "newFilename": .string(newFilename)])
        return try await tracked(.artifactRename, args, purpose: purpose) {
            try requireProfileMutation(.artifactRename)
            try await requireApproval(action: InvocationName.artifactRename.rawValue, args: args.toAny())
            let artifact = try await repository.renameArtifact(named: filename, to: newFilename, in: scope)
            renameArtifactReferences(
                from: filename,
                to: artifact.fileName,
                directory: artifact.fileURL.deletingLastPathComponent()
            )
            onPersistableChange?()
            Log.session.info("bridge.artifact.rename from=\(filename) to=\(artifact.fileName)")
            return try Self.encodeToJSON(ArtifactLibrary.Item(artifact))
        }
    }

    public func presentArtifact(filename: String, purpose: String) async throws -> JSONValue? {
        let args: JSONValue = .object(["filename": .string(filename)])
        return try await trackedEffect(.artifactPresent, args, purpose: purpose, apply: embedArtifact) {
            let artifact = try await repository.artifact(named: filename, in: scope)
            guard artifact.exists else { throw ArtifactError.missing(filename) }
            return (try Self.encodeToJSON(ArtifactLibrary.Item(artifact)), artifact)
        }
    }

    public func presentArtifacts(filenames: [String], purpose: String) async throws -> JSONValue? {
        let args: JSONValue = .object(["filenames": .array(filenames.map(JSONValue.string))])
        let result = try await trackedEffect(
            .artifactPresent,
            args,
            purpose: purpose,
            apply: { artifacts in artifacts.forEach(embedArtifact) }
        ) {
            var artifacts: [Artifact] = []
            for filename in filenames {
                let artifact = try await repository.artifact(named: filename, in: scope)
                guard artifact.exists else { throw ArtifactError.missing(filename) }
                artifacts.append(artifact)
            }
            return (try Self.encodeToJSON(artifacts.map(ArtifactLibrary.Item.init)), artifacts)
        }
        Log.session.info("bridge.artifact.present count=\(filenames.count)")
        return result
    }

    func importRemoteMCPArtifacts(_ values: [RemoteMCPArtifact]) async throws {
        guard !values.isEmpty else { return }
        try requireProfileMutation(.artifactImport)
        var artifacts: [Artifact] = []
        for value in values {
            artifacts.append(try await ArtifactImporter.importDataAsync(
                value.data,
                suggestedName: value.suggestedFilename,
                in: scope
            ))
        }
        for artifact in artifacts { embedArtifact(artifact) }
        Log.session.info("Chat.importRemoteMCPArtifacts count=\(artifacts.count) bytes=\(values.reduce(0) { $0 + $1.data.count })")
    }
}
