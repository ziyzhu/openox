import Foundation
import CryptoKit

/// Provider-neutral boundary. Ox-only signatures/references stay in strict JSON; no credentials or host paths enter Pi.
nonisolated enum DurableMessageCodec {
    static func blocks(_ blocks: [ContentBlock], profileID: UUID? = nil) -> [JSONValue] {
        blocks.map { block in
            switch block {
            case .text(let value):
                return object(["type": "text", "text": value.text, "textSignature": value.textSignature,
                               "oxThoughtSignature": value.thoughtSignature])
            case .thinking(let value):
                return object(["type": "thinking", "thinking": value.thinking, "thinkingSignature": value.thinkingSignature,
                               "oxThoughtSignature": value.thoughtSignature])
            case .toolCall(let call):
                return object(["type": "toolCall", "id": call.id, "name": call.name, "arguments": call.arguments.toAny(),
                               "thoughtSignature": call.thoughtSignature, "oxProviderItemID": call.providerItemID,
                               "oxProviderCallID": call.providerCallID])
            case .attachment(let artifact):
                var reference: [String: JSONValue] = ["type": .string("text"), "text": .string("[Attachment: artifacts/\(artifact.fileName)]"),
                                                      "oxAttachment": .string(artifact.fileName)]
                if let profileID { reference["oxProfileID"] = .string(profileID.uuidString) }
                return .object(reference)
            }
        }
    }

    static func toolDetails(_ result: ToolResultMessage) throws -> String {
        var details = result
        details.content = []
        return try JSONEncoder().encode(details).base64EncodedString()
    }

    static func usage(_ value: Usage) -> JSONValue {
        .object(["input": .int(max(0, value.input - value.cachedInput - (value.cacheWriteInput ?? 0))), "output": .int(value.output), "cacheRead": .int(value.cachedInput),
                 "cacheWrite": .int(value.cacheWriteInput ?? 0), "oxCacheWriteInputKnown": .bool(value.cacheWriteInput != nil), "totalTokens": .int(value.totalTokens),
                 "cost": .object(["input": .int(0), "output": .int(0), "cacheRead": .int(0), "cacheWrite": .int(0), "total": .int(0)])])
    }

    static func message(_ message: Message, provider: String, profileID: UUID? = nil) -> JSONValue {
        switch message {
        case .user(let user):
            var content = blocks(user.content, profileID: profileID)
            if let context = user.transientContext {
                content.append(.object(["type": .string("text"), "text": .string(context), "oxTransientContext": .bool(true)]))
            }
            return .object(["role": .string("user"), "content": .array(content), "timestamp": .double(user.timestamp.timeIntervalSince1970 * 1000)])
        case .assistant(let assistant):
            return object(["role": "assistant", "api": "ox-native", "provider": provider, "model": assistant.model,
                           "content": blocks(assistant.content, profileID: profileID).map { $0.toAny() }, "usage": usage(assistant.usage).toAny(),
                           "stopReason": assistant.stopReason.rawValue, "errorMessage": assistant.errorMessage,
                           "oxFailureKind": assistant.failureKind?.rawValue, "responseId": assistant.responseID,
                           "rawStopReason": assistant.rawStopReason, "timestamp": assistant.timestamp.timeIntervalSince1970 * 1000])
        case .toolResult(let result):
            return object(["role": "toolResult", "toolCallId": result.toolCallId, "toolName": result.toolName,
                           "content": blocks(result.content, profileID: profileID).map { $0.toAny() }, "isError": result.isError,
                           "timestamp": result.timestamp.timeIntervalSince1970 * 1000,
                           "details": try? toolDetails(result)])
        }
    }

    static func transientReference(_ attachment: TransientAttachment, receipt: JSONValue, profileID: UUID) throws -> JSONValue {
        guard let fields = receipt.objectValue, let path = fields["path"]?.stringValue,
              path.hasPrefix("artifacts/"), fields["size"]?.intValue == attachment.data.count,
              let digest = fields["sha256"]?.stringValue,
              digest == SHA256.hash(data: attachment.data).map({ String(format: "%02x", $0) }).joined() else {
            throw RuntimeError.bridge("Transient publication does not match its immutable bytes")
        }
        let name = String(path.dropFirst("artifacts/".count))
        _ = try ArtifactStore.validatedFilename(name)
        let kind: String
        switch attachment.kind {
        case .image: kind = "image"
        case .pdf: kind = "pdf"
        case .text: kind = "text"
        case .file: kind = "file"
        }
        return .object([
            "type": .string("text"), "text": .string("[Attachment: \(attachment.displayName)]"),
            "oxAttachment": .string(name), "oxProfileID": .string(profileID.uuidString),
            "oxTransientAttachment": .object([
                "kind": .string(kind), "mimeType": .string(attachment.mimeType), "displayName": .string(attachment.displayName),
                "size": .int(attachment.data.count), "sha256": .string(digest),
            ]),
        ])
    }

    static func decodeModel(_ value: JSONValue, scope: ProfileScope, artifactScope: ProfileScope? = nil, runtime: DurableRuntime,
                            runtimeProfileID: String? = nil, inputs: ProviderArtifactInputs) async throws -> Message {
        let message = try decode(value, scope: scope, artifactScope: artifactScope, includeTransientReferences: false)
        let references = (value.objectValue?["content"]?.arrayValue ?? []).filter { $0.objectValue?["oxTransientAttachment"] != nil }
        let ownerID = runtimeProfileID ?? (artifactScope ?? scope).profileID?.uuidString
        var result: ToolResultMessage
        switch message {
        case .user(var user):
            guard references.isEmpty else { throw RuntimeError.bridge("Transient media requires a tool result") }
            user.content = try await modelContent(user.content, scope: scope, artifactScope: artifactScope, runtime: runtime, runtimeProfileID: ownerID, inputs: inputs)
            return .user(user)
        case .assistant(var assistant):
            guard references.isEmpty else { throw RuntimeError.bridge("Transient media requires a tool result") }
            assistant.content = try await modelContent(assistant.content, scope: scope, artifactScope: artifactScope, runtime: runtime, runtimeProfileID: ownerID, inputs: inputs)
            return .assistant(assistant)
        case .toolResult(let tool):
            result = tool
            result.content = try await modelContent(tool.content, scope: scope, artifactScope: artifactScope, runtime: runtime, runtimeProfileID: ownerID, inputs: inputs)
        }
        for reference in references {
            guard let fields = reference.objectValue, let descriptor = fields["oxTransientAttachment"]?.objectValue,
                  let name = fields["oxAttachment"]?.stringValue,
                  let profileID = fields["oxProfileID"]?.stringValue,
                  profileID == (artifactScope ?? scope).profileID?.uuidString,
                  let size = descriptor["size"]?.intValue, (0...32 * 1024 * 1024).contains(size),
                  let digest = descriptor["sha256"]?.stringValue,
                  digest.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) }),
                  let mimeType = descriptor["mimeType"]?.stringValue,
                  let displayName = descriptor["displayName"]?.stringValue else {
                throw RuntimeError.bridge("Transient reference does not belong to its immutable artifact owner")
            }
            _ = try ArtifactStore.validatedFilename(name)
            let kind: TransientAttachment.Kind
            switch descriptor["kind"]?.stringValue {
            case "image": kind = .image
            case "pdf": kind = .pdf
            case "text": kind = .text
            case "file": kind = .file
            default: throw RuntimeError.bridge("Invalid transient media kind")
            }
            let data = try await runtime.readArtifact(descriptor: .object([
                "path": .string("artifacts/\(name)"), "size": .int(size), "sha256": .string(digest),
            ]))
            guard data.count == size else { throw RuntimeError.bridge("Transient artifact size does not match its reference") }
            let artifact = Artifact(fileName: name, directory: (artifactScope ?? scope).root.appendingPathComponent("artifacts", isDirectory: true), size: size)
            _ = try inputs.snapshot(artifact, data: data)
            result.transientAttachments.append(TransientAttachment(kind: kind, mimeType: mimeType, displayName: displayName, data: data))
        }
        return .toolResult(result)
    }

    private static func modelContent(_ content: [ContentBlock], scope: ProfileScope, artifactScope: ProfileScope?, runtime: DurableRuntime,
                                     runtimeProfileID: String?, inputs: ProviderArtifactInputs) async throws -> [ContentBlock] {
        var verified: [ContentBlock] = []
        for block in content {
            guard case .attachment(let artifact) = block else { verified.append(block); continue }
            if let cached = inputs.cached(artifact) { verified.append(.attachment(cached)); continue }
            let directory = artifact.fileURL.deletingLastPathComponent().standardizedFileURL
            let owner: ProfileScope
            if let artifactScope, directory.path == artifactScope.root.appendingPathComponent("artifacts", isDirectory: true).standardizedFileURL.path {
                owner = artifactScope
            } else if directory.path == scope.root.appendingPathComponent("artifacts", isDirectory: true).standardizedFileURL.path {
                owner = scope
            } else {
                throw RuntimeError.bridge("Provider attachment belongs to another immutable Profile scope")
            }
            let reader: DurableRuntime
            if owner.profileID?.uuidString == runtimeProfileID {
                reader = runtime
            } else {
                let session = try await DurableProfileStore.shared.session(in: owner)
                reader = session.runtime
            }
            let path = "artifacts/\(artifact.fileName)"
            let request = JSONValue.object(["action": .string("fileArtifact"), "path": .string(path)])
            let metadata = try JSONDecoder().decode(JSONValue.self, from: Data(try await reader.command(request.jsonString()).utf8))
            guard let descriptor = metadata.objectValue?["artifact"], descriptor.objectValue?["path"]?.stringValue == path else {
                throw RuntimeError.bridge("Provider attachment has no immutable committed descriptor")
            }
            let data = try await reader.readArtifact(descriptor: descriptor)
            verified.append(.attachment(try inputs.snapshot(artifact, data: data)))
        }
        return verified
    }

    static func decode(_ value: JSONValue, scope: ProfileScope, artifactScope: ProfileScope? = nil, includeTransientReferences: Bool = true) throws -> Message {
        guard let fields = value.objectValue, let role = fields["role"]?.stringValue else { throw RuntimeError.bridge("Invalid Pi message") }
        let timestamp = Date(timeIntervalSince1970: (fields["timestamp"]?.doubleValue ?? 0) / 1000)
        let values = fields["content"]?.arrayValue ?? fields["content"]?.stringValue.map {
            [.object(["type": .string("text"), "text": .string($0)])]
        } ?? []
        let content = try values.filter {
            $0.objectValue?["oxTransientContext"]?.boolValue != true && (includeTransientReferences || $0.objectValue?["oxTransientAttachment"] == nil)
        }.map { try decodeBlock($0, scope: scope, artifactScope: artifactScope) }
        switch role {
        case "user":
            let context = values.filter { $0.objectValue?["oxTransientContext"]?.boolValue == true }
                .compactMap { $0.objectValue?["text"]?.stringValue }.joined(separator: "\n")
            return .user(UserMessage(content: content, transientContext: context.isEmpty ? nil : context, timestamp: timestamp))
        case "assistant":
            var message = AssistantMessage(model: fields["model"]?.stringValue ?? "unknown", content: content)
            message.timestamp = timestamp
            message.stopReason = fields["stopReason"]?.stringValue.flatMap(StopReason.init(rawValue:)) ?? .pending
            message.errorMessage = fields["errorMessage"]?.stringValue
            message.failureKind = fields["oxFailureKind"]?.stringValue.flatMap(LLMFailureKind.init(rawValue:))
            message.responseID = fields["responseId"]?.stringValue
            message.rawStopReason = fields["rawStopReason"]?.stringValue
            let usage = fields["usage"]?.objectValue ?? [:]
            message.usage.input = (usage["input"]?.intValue ?? 0) + (usage["cacheRead"]?.intValue ?? 0) + (usage["cacheWrite"]?.intValue ?? 0)
            message.usage.output = usage["output"]?.intValue ?? 0
            message.usage.cachedInput = usage["cacheRead"]?.intValue ?? 0
            message.usage.cacheWriteInput = usage["oxCacheWriteInputKnown"]?.boolValue == false ? nil : usage["cacheWrite"]?.intValue
            message.usage.totalTokens = usage["totalTokens"]?.intValue ?? 0
            return .assistant(message)
        case "toolResult":
            if let encoded = fields["details"]?.stringValue, let data = Data(base64Encoded: encoded) {
                let decoder = JSONDecoder(); decoder.userInfo[.profileScope] = artifactScope ?? scope
                var result = try decoder.decode(ToolResultMessage.self, from: data)
                // Historical native details retain ancillary fields, not a competing
                // attachment authority. Use the already-validated qualified content.
                result.content = content
                return .toolResult(result)
            }
            return .toolResult(ToolResultMessage(toolCallId: fields["toolCallId"]?.stringValue ?? "",
                                                toolName: fields["toolName"]?.stringValue ?? "",
                                                content: content, isError: fields["isError"]?.boolValue == true, timestamp: timestamp))
        default: throw RuntimeError.bridge("Unsupported Pi message role \(role)")
        }
    }

    static func decodeToolCall(_ value: JSONValue, scope: ProfileScope, artifactScope: ProfileScope? = nil) throws -> ToolCall {
        guard case .toolCall(let call) = try decodeBlock(value, scope: scope, artifactScope: artifactScope) else {
            throw RuntimeError.bridge("Expected an authoritative Pi tool call")
        }
        return call
    }

    private static func decodeBlock(_ value: JSONValue, scope: ProfileScope, artifactScope: ProfileScope?) throws -> ContentBlock {
        let fields = value.objectValue ?? [:]
        if let name = fields["oxAttachment"]?.stringValue {
            _ = try ArtifactStore.validatedFilename(name)
            let owner: ProfileScope
            if let profileID = fields["oxProfileID"]?.stringValue {
                guard let identity = UUID(uuidString: profileID) else { throw RuntimeError.bridge("Invalid attachment Profile identity") }
                if let artifactScope, artifactScope.profileID == identity { owner = artifactScope }
                else if scope.profileID == identity { owner = scope }
                else { throw RuntimeError.bridge("Attachment reference belongs to another Profile") }
            } else { owner = scope } // Existing UUID-bound cache/legacy codec compatibility.
            return .attachment(Artifact(fileName: name, directory: owner.root.appendingPathComponent("artifacts")))
        }
        switch fields["type"]?.stringValue {
        case "text": return .text(TextContent(fields["text"]?.stringValue ?? "", textSignature: fields["textSignature"]?.stringValue,
                                              thoughtSignature: fields["oxThoughtSignature"]?.stringValue))
        case "thinking": return .thinking(ThinkingContent(fields["thinking"]?.stringValue ?? "", thinkingSignature: fields["thinkingSignature"]?.stringValue,
                                                          thoughtSignature: fields["oxThoughtSignature"]?.stringValue))
        case "toolCall": return .toolCall(ToolCall(id: fields["id"]?.stringValue ?? "", name: fields["name"]?.stringValue ?? "",
                                                  arguments: fields["arguments"] ?? .object([:]), thoughtSignature: fields["thoughtSignature"]?.stringValue,
                                                  providerItemID: fields["oxProviderItemID"]?.stringValue, providerCallID: fields["oxProviderCallID"]?.stringValue))
        default: throw RuntimeError.bridge("Unsupported Pi content block")
        }
    }

    static func event(_ event: AssistantEvent, provider: String) -> JSONValue {
        func partial(_ message: AssistantMessage) -> JSONValue { self.message(.assistant(message), provider: provider) }
        switch event {
        case .start(let message): return .object(["type": .string("start"), "partial": partial(message)])
        case .textDelta(let index, let delta, let message): return .object(["type": .string("text_delta"), "contentIndex": .int(index), "delta": .string(delta), "partial": partial(message)])
        case .thinkingDelta(let index, let delta, let message): return .object(["type": .string("thinking_delta"), "contentIndex": .int(index), "delta": .string(delta), "partial": partial(message)])
        case .toolCallDelta(let index, let message): return .object(["type": .string("toolcall_delta"), "contentIndex": .int(index), "delta": .string(""), "partial": partial(message)])
        case .textEnd(let index, let message): return .object(["type": .string("text_end"), "contentIndex": .int(index), "content": .string(""), "partial": partial(message)])
        case .thinkingEnd(let index, let message): return .object(["type": .string("thinking_end"), "contentIndex": .int(index), "content": .string(""), "partial": partial(message)])
        case .toolCallEnd(let index, let call, let message): return .object(["type": .string("toolcall_end"), "contentIndex": .int(index), "toolCall": blocks([.toolCall(call)])[0], "partial": partial(message)])
        case .done(let reason, let message): return .object(["type": .string("done"), "reason": .string(reason.rawValue), "message": partial(message)])
        case .failed(let reason, let message): return .object(["type": .string("error"), "reason": .string(reason.rawValue), "error": partial(message)])
        }
    }

    private static func object(_ values: [String: Any?]) -> JSONValue {
        .from(values.compactMapValues { $0 })
    }
}
