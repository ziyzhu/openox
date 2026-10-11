import Foundation

extension OxHostProtocol {
    static let durableTemporarySessionID = ProcessInfo.processInfo.environment["OX_DURABLE_TEMPORARY_SESSION"].flatMap(UUID.init(uuidString:))

    #if DEBUG && targetEnvironment(simulator)
    struct DurableConversationRequest: Codable {
        let caseID: UUID
        let action: String
        let sessionId: String?
        let path: String?
        let text: String?
        let artifactFiles: Bool?
        let reference: JSONValue?
        let limit: Int?
        let historyCursor: JSONValue?
        let listCursor: JSONValue?
        let presentation: JSONValue?
        let lastReadEntryID: Int?
    }
    #endif

    @MainActor
    static func prepareDurableTemporaryConversation(_ conversation: Conversation, caseID: UUID) async throws {
        _ = try await DurableConversationController.attach(conversation, caseID: caseID, artifactFiles: true)
    }

    @MainActor
    static func releaseDurableTemporaryConversation(_ conversation: Conversation) async {
        await conversation.waitForRun()
        await DurableConversationController.release(conversation)
    }

    #if DEBUG && targetEnvironment(simulator)
    @MainActor
    static func handleDurableConversation(_ request: DurableConversationRequest, conversations: ConversationManager, reply: OxHostRPC.Reply) {
        Task { @MainActor in
            do { reply.success(try await DurableConversationController.command(request, conversations: conversations)) }
            catch { reply.failure(error.localizedDescription) }
        }
    }
    #endif
}

@MainActor
private enum DurableConversationController {
    struct Session {
        let runtime: DurableRuntime
        let host: DurableAgentHost
        let scope: ProfileScope
        let artifactFiles: Bool
        let artifactScope: ProfileScope?
        var conversations: [UUID: Conversation] = [:]
        var opening = true
        var closing = false
    }
    static var sessions: [UUID: Session] = [:]
    static var attaching: Set<UUID> = []

    static func attach(_ conversation: Conversation, caseID: UUID, artifactFiles requestedBackend: Bool?) async throws -> JSONValue {
        guard conversation.isTemporary, !conversation.isBusy else { throw RuntimeError.bridge("Durable rollout requires an idle temporary conversation") }
        guard !attaching.contains(conversation.id), !sessions.contains(where: { $0.key != caseID && $0.value.conversations[conversation.id] != nil }) else {
            throw RuntimeError.bridge("Conversation already belongs to another durable Session or attachment")
        }
        attaching.insert(conversation.id)
        defer { attaching.remove(conversation.id) }
        if sessions[caseID] == nil {
            guard sessions.count < 2 else { throw RuntimeError.bridge("Close another durable Session first") }
            let host = DurableAgentHost()
            let physical = requestedBackend != false
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appending(path: "PiDurableProof/\(physical ? "NativeFiles" : "Native")/\(caseID.uuidString)")
            if physical { try await ProfileMigrator.prepareTemporaryFiles(at: directory, identity: caseID) }
            let runtime = DurableRuntime(databaseURL: directory.appending(path: physical ? "state.sqlite" : "session.sqlite"),
                fileRoot: physical ? directory : nil) { method, params, stream in try await host.handle(method, params, stream: stream) }
            let artifactScope = physical ? ProfileScope(profileID: caseID, root: directory, location: .local) : nil
            sessions[caseID] = Session(runtime: runtime, host: host, scope: conversation.scope, artifactFiles: physical, artifactScope: artifactScope)
            do {
                _ = try await runtime.command(JSONValue.object(["action": .string("open"), "profileID": .string(caseID.uuidString), "artifactFiles": .bool(physical), "physicalFiles": .bool(physical), "publicFiles": .bool(physical)]).jsonString())
                sessions[caseID]?.opening = false
            } catch { await runtime.dispose(); sessions.removeValue(forKey: caseID); throw error }
        }
        guard var session = sessions[caseID], !session.opening, !session.closing, session.scope == conversation.scope,
              requestedBackend == nil || requestedBackend == session.artifactFiles else { throw RuntimeError.bridge("Session unavailable or bound to another Profile scope") }
        guard session.conversations.count < 8 || session.conversations[conversation.id] != nil else { throw RuntimeError.bridge("Durable Session conversation limit reached") }
        let resources = try await session.runtime.fileMounts(scope: caseID)
        let conversationID: Int
        if let route = conversation.durableRoute, route.session.runtime === session.runtime {
            conversationID = route.conversationID
        } else {
            let identity = try await session.runtime.command(.object(["action": .string("conversationCreate")]))
            guard let id = identity.objectValue?["reference"]?.objectValue?["conversationID"]?.intValue,
                  identity.objectValue?["reference"]?.objectValue?["profileID"]?.stringValue == caseID.uuidString else {
                throw RuntimeError.bridge("Temporary conversation belongs to another runtime")
            }
            conversationID = id
        }
        try conversation.installDurableRoute(DurableConversationRoute(
            session: .init(runtime: session.runtime, host: session.host, scope: conversation.scope, resources: resources, skills: try await session.runtime.skillPackages(scope: caseID)),
            conversationID: conversationID, profileID: caseID, artifactScope: session.artifactScope, reference: nil))
        session.conversations[conversation.id] = conversation; sessions[caseID] = session
        Log.agent.info("PiDurable rollout attached temporary=\(conversation.id) case=\(caseID) conversation=\(conversationID) profile=\(conversation.scope.profileID?.uuidString ?? "nil")")
        return .object(["attached": .bool(true), "conversationID": .int(conversationID)])
    }

    static func release(_ conversation: Conversation) async {
        guard let entry = sessions.first(where: { $0.value.conversations[conversation.id] != nil }) else { return }
        var session = entry.value
        session.conversations[conversation.id] = nil
        if let conversationID = conversation.durableRoute?.conversationID { await session.host.unbind(conversationID: conversationID) }
        if !session.conversations.isEmpty { sessions[entry.key] = session; return }
        session.closing = true; sessions[entry.key] = session
        do {
            _ = try await session.runtime.command(JSONValue.object(["action": .string("close")]).jsonString())
            await session.runtime.dispose()
            sessions.removeValue(forKey: entry.key)
            if entry.key != OxHostProtocol.durableTemporarySessionID, let root = session.artifactScope?.root { try FileManager.default.removeItem(at: root) }
        } catch { Log.agent.error("PiDurable temporary close failed=\(error.localizedDescription)") }
    }

    #if DEBUG && targetEnvironment(simulator)
    static func command(_ request: OxHostProtocol.DurableConversationRequest, conversations: ConversationManager) async throws -> JSONValue {
        if request.action == "attach" {
            guard case .found(let conversation?) = OxHostProtocol.resolveSession(conversations, request.sessionId), conversation.isTemporary, !conversation.isBusy else {
                throw RuntimeError.bridge("Durable rollout requires an idle temporary conversation; persisted conversations remain behind the storage migration gate")
            }
            return try await attach(conversation, caseID: request.caseID, artifactFiles: request.artifactFiles)
        }
        guard var session = sessions[request.caseID], !session.opening, !session.closing else { throw RuntimeError.bridge("Attach an isolated durable Session first") }
        guard ["inspect", "fileWrite", "fileRead", "fileReference", "fileRemove", "conversationList", "conversationMetadata",
               "conversationHistory", "conversationPresent", "conversationRead", "close"].contains(request.action) else { throw RuntimeError.bridge("Unknown durable rollout command") }
        if request.action == "close" {
            guard session.conversations.values.allSatisfy({ !$0.isBusy }) else { throw RuntimeError.bridge("Stop active conversations before closing the rollout Session") }
            session.closing = true; sessions[request.caseID] = session
        }
        let reference: JSONValue?
        if let sessionID = request.sessionId {
            guard let id = UUID(uuidString: sessionID), let conversation = session.conversations[id], let route = conversation.durableRoute else {
                throw RuntimeError.bridge("Temporary conversation is not attached")
            }
            reference = route.runtimeReference
            if let expected = request.reference, expected != .null, expected != reference {
                throw RuntimeError.bridge("Conversation identity mismatch")
            }
        } else { reference = request.reference }
        let value = JSONValue.object(["action": .string(request.action), "path": request.path.map(JSONValue.string) ?? .null,
                                      "text": request.text.map(JSONValue.string) ?? .null,
                                      "reference": reference ?? .null, "limit": request.limit.map(JSONValue.int) ?? .int(100),
                                      "historyCursor": request.historyCursor ?? .null, "listCursor": request.listCursor ?? .null,
                                      "presentation": request.presentation ?? .null, "lastReadEntryID": request.lastReadEntryID.map(JSONValue.int) ?? .null])
        do {
            let result = try await session.runtime.command(value.jsonString(), entry: "agentCommand")
            if request.action == "close" {
                for conversation in session.conversations.values {
                    if let conversationID = conversation.durableRoute?.conversationID { await session.host.unbind(conversationID: conversationID) }
                    try conversation.installDurableRoute(nil)
                }
                await session.runtime.dispose(); sessions.removeValue(forKey: request.caseID)
            }
            return try JSONDecoder().decode(JSONValue.self, from: Data(result.utf8))
        } catch {
            if request.action == "close" { sessions[request.caseID]?.closing = false }
            throw error
        }
    }
    #endif
}
