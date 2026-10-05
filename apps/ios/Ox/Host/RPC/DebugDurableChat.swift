#if DEBUG && targetEnvironment(simulator)
import Foundation

extension OxHostProtocol {
    struct DurableChatRequest: Codable {
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
    @MainActor
    static func handleDurableChat(_ request: DurableChatRequest, chats: ChatManager, reply: OxHostRPC.Reply) {
        Task { @MainActor in
            do { reply.success(try await DurableChatController.command(request, chats: chats)) }
            catch { reply.failure(error.localizedDescription) }
        }
    }
}

/// Deliberate rollout gate: real native providers/capabilities and chat presentation, synthetic cache storage only.
/// Persisted chats are refused so the legacy transcript cannot become a second authority for the same conversation.
@MainActor
private enum DurableChatController {
    struct Session {
        let runtime: DurableRuntime
        let host: DurableAgentHost
        let scope: ProfileScope
        let artifactFiles: Bool
        let artifactScope: ProfileScope?
        var chats: [UUID: Chat] = [:]
        var opening = true
        var closing = false
    }
    static var sessions: [UUID: Session] = [:]
    static var attaching: Set<UUID> = []

    static func command(_ request: OxHostProtocol.DurableChatRequest, chats: ChatManager) async throws -> JSONValue {
        if request.action == "attach" {
            guard case .found(let chat?) = OxHostProtocol.resolveSession(chats, request.sessionId), chat.isTemporary, !chat.isBusy else {
                throw RuntimeError.bridge("Durable rollout requires an idle temporary chat; persisted chats remain behind the storage migration gate")
            }
            guard !attaching.contains(chat.id), !sessions.contains(where: { $0.key != request.caseID && $0.value.chats[chat.id] != nil }) else {
                throw RuntimeError.bridge("Chat already belongs to another durable Session or attachment")
            }
            attaching.insert(chat.id)
            defer { attaching.remove(chat.id) }
            if sessions[request.caseID] == nil {
                guard sessions.count < 2 else { throw RuntimeError.bridge("Close another durable Session first") }
                let host = DurableAgentHost()
                let artifactFiles = request.artifactFiles == true
                let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appending(path: "PiDurableProof/\(artifactFiles ? "NativeFiles" : "Native")/\(request.caseID.uuidString)")
                let runtime = DurableRuntime(databaseURL: directory.appending(path: artifactFiles ? "state.sqlite" : "session.sqlite"),
                                             artifactRoot: artifactFiles ? directory : nil) { method, params, stream in
                    try await host.handle(method, params, stream: stream)
                }
                let artifactScope = artifactFiles ? ProfileScope(profileID: request.caseID, root: directory, location: .local) : nil
                sessions[request.caseID] = Session(runtime: runtime, host: host, scope: chat.scope, artifactFiles: artifactFiles, artifactScope: artifactScope)
                do {
                    _ = try await runtime.command(JSONValue.object(["action": .string("open"), "profileID": .string(request.caseID.uuidString), "artifactFiles": .bool(artifactFiles)]).jsonString(), entry: "agentCommand")
                    sessions[request.caseID]?.opening = false
                } catch {
                    await runtime.dispose(); sessions.removeValue(forKey: request.caseID); throw error
                }
            }
            guard var session = sessions[request.caseID], !session.opening, !session.closing, session.scope == chat.scope,
                  request.artifactFiles == nil || request.artifactFiles == session.artifactFiles else {
                throw RuntimeError.bridge("Session unavailable or bound to another Profile scope")
            }
            guard session.chats.count < 8 || session.chats[chat.id] != nil else { throw RuntimeError.bridge("Durable Session chat limit reached") }
            try await chat.agent.installDurableDriver(DurableAgentDriver(runtime: session.runtime, host: session.host, chatID: chat.id, scope: chat.scope, runtimeProfileID: request.caseID, artifactScope: session.artifactScope))
            session.chats[chat.id] = chat; sessions[request.caseID] = session
            Log.agent.info("PiDurable rollout attached chat=\(chat.id) case=\(request.caseID) profile=\(chat.scope.profileID?.uuidString ?? "nil")")
            return .object(["attached": .bool(true), "chatID": .string(chat.id.uuidString)])
        }
        guard var session = sessions[request.caseID], !session.opening, !session.closing else { throw RuntimeError.bridge("Attach an isolated durable Session first") }
        guard ["inspect", "fileWrite", "fileRead", "fileReference", "fileRemove", "conversationList", "conversationMetadata",
               "conversationHistory", "conversationPresent", "conversationRead", "close"].contains(request.action) else { throw RuntimeError.bridge("Unknown durable rollout command") }
        if request.action == "close" {
            guard session.chats.values.allSatisfy({ !$0.isBusy }) else { throw RuntimeError.bridge("Stop active chats before closing the rollout Session") }
            session.closing = true; sessions[request.caseID] = session
        }
        let value = JSONValue.object(["action": .string(request.action), "chatID": request.sessionId.map(JSONValue.string) ?? .null, "path": request.path.map(JSONValue.string) ?? .null,
                                      "text": request.text.map(JSONValue.string) ?? .null,
                                      "reference": request.reference ?? .null, "limit": request.limit.map(JSONValue.int) ?? .int(100),
                                      "historyCursor": request.historyCursor ?? .null, "listCursor": request.listCursor ?? .null,
                                      "presentation": request.presentation ?? .null, "lastReadEntryID": request.lastReadEntryID.map(JSONValue.int) ?? .null])
        do {
            let result = try await session.runtime.command(value.jsonString(), entry: "agentCommand")
            if request.action == "close" {
                for chat in session.chats.values {
                    try await chat.agent.installDurableDriver(nil)
                    await session.host.unbind(chatID: chat.id.uuidString)
                }
                await session.runtime.dispose(); sessions.removeValue(forKey: request.caseID)
            }
            return try JSONDecoder().decode(JSONValue.self, from: Data(result.utf8))
        } catch {
            if request.action == "close" { sessions[request.caseID]?.closing = false }
            throw error
        }
    }
}
#endif
