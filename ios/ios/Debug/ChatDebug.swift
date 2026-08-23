import Foundation
import Observation

struct DebugSnapshot: Encodable {
    let id: String
    let model: ProviderModel
    let systemPrompt: String
    let renderedSystemPrompt: String
    let soul: String
    let memory: String
    let tools: [ToolDecl]
    let messages: [Message]
    let blocks: [Block]

    struct ToolDecl: Encodable {
        let name: String
        let description: String
        let parameters: JSONValue
        let strict: Bool

        init(_ tool: any AgentTool) {
            name = tool.name
            description = tool.description
            parameters = tool.parameters
            strict = tool.strict
        }
    }

    @MainActor
    init(_ chat: Chat) {
        let agent = chat.agentSnapshot
        id = chat.id.uuidString
        model = agent?.model ?? chat.model
        let toolsAvailable = chat.client.supportsTools(for: chat.model)
        let currentMemory = UserMemory.shared.text
        let userSkills = Skills.shared.all
        let breakdown = Chat.systemPromptBreakdown(
            memory: currentMemory,
            userSkills: userSkills,
            toolsAvailable: toolsAvailable
        )
        systemPrompt = breakdown.scaffold
        renderedSystemPrompt = agent?.systemPrompt ?? Chat.composeSystemPrompt(
            memory: currentMemory,
            userSkills: userSkills,
            toolsAvailable: toolsAvailable
        )
        soul = breakdown.soul
        memory = breakdown.memory
        tools = (agent?.tools ?? []).map(ToolDecl.init)
        messages = agent?.messages ?? []
        blocks = chat.transcript
    }
}

struct DebugHeader: Encodable {
    let id: String
    let model: ProviderModel
    let systemPrompt: String
    let renderedSystemPrompt: String
    let soul: String
    let memory: String
    let tools: [DebugSnapshot.ToolDecl]

    init(_ s: DebugSnapshot) {
        id = s.id
        model = s.model
        systemPrompt = s.systemPrompt
        renderedSystemPrompt = s.renderedSystemPrompt
        soul = s.soul
        memory = s.memory
        tools = s.tools
    }
}

struct DebugDelta: Encodable {
    let id: String
    let messages: [Message]
    let blocks: [Block]

    init(_ s: DebugSnapshot) {
        id = s.id
        messages = s.messages
        blocks = s.blocks
    }
}

@MainActor
final class DebugPublisher {
    static let shared = DebugPublisher()

    private weak var chat: Chat?
    private var pendingSend: Task<Void, Never>?
    private var lastHeader: Data?
    private var lastDelta: Data?
    private var loggedMessages = -1
    private var loggedBlocks = -1
    private static let debounceNs: UInt64 = 100_000_000

    private init() {
        #if targetEnvironment(simulator)
        DebugServer.shared.onConnect = { [weak self] in
            [self?.lastHeader, self?.lastDelta].compactMap { $0 }
        }
        #endif
    }

    func observe(_ chat: Chat?) {
        pendingSend?.cancel()
        self.chat = chat
        lastHeader = nil
        lastDelta = nil
        loggedMessages = -1
        loggedBlocks = -1
        #if targetEnvironment(simulator)
        guard let chat else {
            Log.agent.info("DebugPublisher.observe id=nil (clearing)")
            if let payload = encode(Wire<DebugSnapshot>(type: "clear", data: nil)) {
                DebugServer.shared.broadcast(payload)
            }
            return
        }
        Log.agent.info("DebugPublisher.observe id=\(chat.id)")
        scheduleSend()
        #else
        self.chat = nil
        #endif
    }

    private func scheduleSend() {
        pendingSend?.cancel()
        pendingSend = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNs)
            guard !Task.isCancelled, let self else { return }
            self.captureAndSend()
        }
    }

    private func captureAndSend() {
        guard let chat else { return }
        let snapshot: DebugSnapshot = withObservationTracking {
            DebugSnapshot(chat)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleSend() }
        }
        #if targetEnvironment(simulator)
        if let header = encode(Wire(type: "header", data: DebugHeader(snapshot))), header != lastHeader {
            lastHeader = header
            DebugServer.shared.broadcast(header)
            Log.agent.info("DebugPublisher -> header id=\(snapshot.id.prefix(8)) model=\(snapshot.model.id) tools=\(snapshot.tools.count) bytes=\(header.count)")
        }
        if let delta = encode(Wire(type: "delta", data: DebugDelta(snapshot))) {
            lastDelta = delta
            DebugServer.shared.broadcast(delta)
            if snapshot.messages.count != loggedMessages || snapshot.blocks.count != loggedBlocks {
                loggedMessages = snapshot.messages.count
                loggedBlocks = snapshot.blocks.count
                Log.agent.info("DebugPublisher -> delta id=\(snapshot.id.prefix(8)) msgs=\(snapshot.messages.count) blocks=\(snapshot.blocks.count) bytes=\(delta.count)")
            }
        }
        #endif
    }

    private struct Wire<T: Encodable>: Encodable {
        let type: String
        let data: T?
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private func encode<T: Encodable>(_ wire: Wire<T>) -> Data? {
        do {
            return try Self.encoder.encode(wire)
        } catch {
            Log.agent.error("DebugPublisher encode failed: \(error.localizedDescription)")
            return nil
        }
    }
}
