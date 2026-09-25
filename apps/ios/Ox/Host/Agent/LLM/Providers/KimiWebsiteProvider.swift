import Foundation
import WebKit

nonisolated private struct KimiWebsiteError: ProviderClientError {
    let message: String
    let failureKind: LLMFailureKind

    init(_ message: String, kind: LLMFailureKind = .provider) {
        self.message = message
        failureKind = kind
    }
}

nonisolated struct KimiWebsiteProvider: ProviderClient {
    let models: [ProviderModel]
    let id = "kimi-web"
    let displayName = "Kimi Website"
    let regions: Set<LLMRegion> = [.global]
    let website = URL(string: "https://www.kimi.com/")
    let usesAPIKey = false
    let supportsTools = true
    let subscriptionAccount: (any SubscriptionAccount)? = nil

    func websiteSessionIsAuthenticated() async throws -> Bool? {
        try await KimiWebGenerationSession.shared.isSignedIn()
    }

    func stream(
        model: ProviderModel,
        systemPrompt: String?,
        messages: [Message],
        tools: [any AgentTool],
        options: StreamOptions
    ) -> AsyncThrowingStream<AssistantEvent, Error> {
        streamingTask(model: model, messages: messages) { continuation in
            guard models.contains(where: { $0.id == model.id }) else {
                throw KimiWebsiteError("This Kimi website model is unavailable")
            }
            guard requiredInputModalities(in: messages).isSubset(of: Set([.text])) else {
                throw KimiWebsiteError("Kimi website supports text only", kind: .unsupportedInput)
            }
            guard options.temperature == nil else {
                throw KimiWebsiteError("Kimi website does not support temperature")
            }
            let toolInstructions = WebsiteToolContract.instructions(tools)
            let prompt = try WebsiteProviderPrompt.prompt(messages: messages, toolInstructions: toolInstructions, providerName: "Kimi")
            let instructions = [systemPrompt, toolInstructions].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            let generationID = try await KimiWebGenerationSession.shared.start(prompt: prompt, systemPrompt: instructions)
            var assembler = StreamAssembler(model: model, continuation: continuation)
            var cursor = 0
            var text = ""
            var emittedText = ""
            var outputIsToolCall = false
            var terminal = false

            do {
                assembler.start()
                while !terminal {
                    try Task.checkCancellation()
                    let update = try await KimiWebGenerationSession.shared.read(generationID, after: cursor)
                    guard update.nextCursor >= cursor,
                          update.nextCursor - cursor == update.events.count else {
                        throw KimiWebsiteError("Kimi generation events are out of order")
                    }
                    cursor = update.nextCursor
                    for event in update.events {
                        guard !terminal else { throw KimiWebsiteError("Kimi sent events after completion") }
                        switch event {
                        case .textSnapshot(let snapshot):
                            guard snapshot.hasPrefix(text) || emittedText.isEmpty else {
                                throw KimiWebsiteError("Kimi revised streamed output; final text was not accepted")
                            }
                            text = snapshot
                            if !outputIsToolCall && WebsiteToolContract.isPossibleCallPrefix(snapshot) {
                                outputIsToolCall = snapshot.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(WebsiteToolContract.start)
                                continue
                            }
                            if outputIsToolCall { continue }
                            guard snapshot.hasPrefix(emittedText) else {
                                throw KimiWebsiteError("Kimi revised streamed output; final text was not accepted")
                            }
                            let delta = String(snapshot.dropFirst(emittedText.count))
                            emittedText = snapshot
                            if !delta.isEmpty { assembler.textDelta(delta) }
                        case .completed:
                            terminal = true
                            await WebsiteAuthenticationCache.set(true, for: id)
                            if !outputIsToolCall && emittedText.isEmpty && WebsiteToolContract.isPossibleCallPrefix(text) {
                                throw KimiWebsiteError("Kimi returned an incomplete Ox Action call")
                            }
                            if outputIsToolCall {
                                guard let call = try WebsiteToolContract.call(from: text, tools: tools) else {
                                    throw KimiWebsiteError("Kimi returned an invalid Ox Action call")
                                }
                                assembler.completeToolCall(call)
                                assembler.finish(reason: .toolUse, label: id, lines: cursor)
                            } else {
                                assembler.finish(reason: .stop, label: id, lines: cursor)
                            }
                        case .failed(let message, let kind):
                            throw KimiWebsiteError(message, kind: kind)
                        }
                    }
                }
            } catch {
                if !(error is CancellationError) {
                    await WebsiteAuthenticationCache.invalidate(id)
                }
                let cancelled = await KimiWebGenerationSession.shared.cancel(generationID)
                Log.agent.info("KimiWebsite.cancel generation=\(generationID) confirmed=\(cancelled)")
                throw error
            }
        }
    }
}

@MainActor
private final class KimiWebGenerationSession: NSObject, WKScriptMessageHandler {
    static let shared = KimiWebGenerationSession()

    private final class Generation {
        let page: WebPage
        var events: [WebsiteGenerationEvent] = []
        var remoteChatID: String?
        var remoteMessageID: String?
        var terminal = false
        var lastEvent = Date()

        init(page: WebPage) { self.page = page }
    }

    private var generations: [UUID: Generation] = [:]
    private let website = URL(string: "https://www.kimi.com/")!
    private let channel = "oxKimiGeneration"

    func isSignedIn() async throws -> Bool {
        let page = WebPage(configuration: IOSHost.shared.services.makeServicePageConfiguration(for: "www.kimi.com"))
        try await load(page)
        _ = try await page.callJavaScript(Self.bridge, arguments: [:], in: nil, contentWorld: .page)
        let result = try await page.callJavaScript(
            "return await window.__oxKimiSignedIn();",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        guard let signedIn = result as? Bool else {
            throw KimiWebsiteError("Kimi sign-in status could not be verified")
        }
        Log.agent.info("KimiWebsite.authentication signedIn=\(signedIn)")
        return signedIn
    }

    func start(prompt: String, systemPrompt: String?) async throws -> UUID {
        guard generations.isEmpty else { throw KimiWebsiteError("Kimi website already has an active generation") }
        let id = UUID()
        var configuration = IOSHost.shared.services.makeServicePageConfiguration(for: "www.kimi.com")
        configuration.userContentController.add(self, name: channel)
        let page = WebPage(configuration: configuration)
        generations[id] = Generation(page: page)
        do {
            try await load(page)
            try Task.checkCancellation()
            _ = try await page.callJavaScript(Self.bridge, arguments: [:], in: nil, contentWorld: .page)
            _ = try await page.callJavaScript(
                "return window.__oxKimiRun(id, prompt, systemPrompt);",
                arguments: ["id": id.uuidString, "prompt": prompt, "systemPrompt": systemPrompt ?? ""],
                in: nil,
                contentWorld: .page
            )
            Log.agent.info("KimiWebsite.start generation=\(id) submission=uncertain")
            return id
        } catch {
            generations.removeValue(forKey: id)
            WebsiteAuthenticationCache.invalidate("kimi-web")
            Log.agent.error("KimiWeb.start failed generation=\(id) error=\(error.localizedDescription)")
            throw KimiWebsiteError("Kimi website request could not start: \(error.localizedDescription)")
        }
    }

    func read(_ id: UUID, after cursor: Int) async throws -> WebsiteGenerationUpdate {
        guard let generation = generations[id] else {
            throw KimiWebsiteError("Kimi generation is no longer available")
        }
        guard cursor >= 0, cursor <= generation.events.count else {
            throw KimiWebsiteError("Kimi generation cursor is invalid")
        }
        let deadline = Date().addingTimeInterval(10)
        while cursor == generation.events.count && !generation.terminal && Date() < deadline {
            try Task.checkCancellation()
            if Date().timeIntervalSince(generation.lastEvent) > 120 {
                generation.events.append(.failed("Kimi stopped sending generation events", .network))
                generation.terminal = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let events = Array(generation.events.dropFirst(cursor))
        let update = WebsiteGenerationUpdate(nextCursor: generation.events.count, events: events)
        if generation.terminal && !events.isEmpty { generations.removeValue(forKey: id) }
        return update
    }

    func cancel(_ id: UUID) async -> Bool {
        guard let generation = generations.removeValue(forKey: id) else { return false }
        do {
            let value = try await generation.page.callJavaScript(
                "return await window.__oxKimiCancel(id);",
                arguments: ["id": id.uuidString],
                in: nil,
                contentWorld: .page
            )
            return value as? Bool == true
        } catch {
            Log.agent.warning("KimiWebsite.cancel generation=\(id) error=\(error.localizedDescription)")
            return false
        }
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard message.name == channel,
                  message.frameInfo.isMainFrame,
                  message.frameInfo.securityOrigin.host == "www.kimi.com",
                  let value = message.body as? [String: Any],
                  let idString = value["id"] as? String,
                  let id = UUID(uuidString: idString),
                  let generation = generations[id],
                  !generation.terminal else { return }
            generation.lastEvent = Date()
            if let chatID = value["chatId"] as? String, !chatID.isEmpty { generation.remoteChatID = chatID }
            if let messageID = value["messageId"] as? String, !messageID.isEmpty {
                if generation.remoteMessageID == nil {
                    Log.agent.info("KimiWeb.submitted generation=\(id) chat=\(generation.remoteChatID ?? "unknown") message=\(messageID)")
                }
                generation.remoteMessageID = messageID
            }
            switch value["type"] as? String {
            case "snapshot":
                if let text = value["text"] as? String { generation.events.append(.textSnapshot(text)) }
            case "completed":
                generation.events.append(.completed)
                generation.terminal = true
            case "failed":
                let detail = value["message"] as? String ?? "Kimi generation failed"
                let kind: LLMFailureKind = detail.contains("Sign in to Kimi")
                    ? .authentication : llmFailureKind(message: detail)
                generation.events.append(.failed(detail, kind))
                generation.terminal = true
            default: break
            }
        }
    }

    private func load(_ page: WebPage) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for try await event in page.load(self.website) {
                    if event == .finished { return }
                }
                throw KimiWebsiteError("Kimi website did not finish loading", kind: .network)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                throw KimiWebsiteError("Kimi website loading timed out", kind: .network)
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private static let bridge = #"""
        if (!window.__oxKimiRun) {
          const active = new Map();
          const send = value => window.webkit.messageHandlers.oxKimiGeneration.postMessage(value);
          const service = async typeName => {
            for (let attempt = 0; attempt < 100; attempt++) {
              const provides = document.querySelector('#app')?.__vue_app__?._context?.provides;
              const provider = provides && Reflect.ownKeys(provides).map(key => provides[key]).find(value => value?.serviceMap instanceof Map);
              const client = provider && [...provider.serviceMap.entries()].find(([descriptor]) => descriptor.typeName === typeName)?.[1];
              if (client) return client;
              await new Promise(resolve => setTimeout(resolve, 100));
            }
            throw new Error('Kimi request client is unavailable');
          };
          window.__oxKimiSignedIn = async () => {
            const account = await service('kimi.gateway.account.v1.UserService');
            const identity = await account.getCurrentUser({});
            return !!identity?.user?.id;
          };
          window.__oxKimiRun = (id, prompt, systemPrompt) => {
            const generation = {controller: new AbortController(), chatId: '', messageId: '', offset: 0, blocks: new Map()};
            active.set(id, generation);
            void (async () => {
              try {
                if (!await window.__oxKimiSignedIn()) throw new Error('Sign in to Kimi in Ox provider settings');
                const client = await service('kimi.gateway.chat.v1.ChatService');
                const message = {
                  $typeName: 'kimi.chat.v1.ChatMessage', id: '', parentId: '', role: 2,
                  blocks: [{$typeName: 'kimi.chat.v1.Block', id: '', messageId: '', content: {
                    case: 'text', value: {$typeName: 'kimi.chat.v1.TextBlock', content: prompt}
                  }}], labels: [], references: [], childrenMessageIds: [], refVotes: []
                };
                const request = {
                  $typeName: 'kimi.gateway.chat.v1.ChatRequest', chatId: '', kimiplusId: '',
                  scenario: 1, tools: [], message,
                  options: {$typeName: 'kimi.gateway.chat.v1.ChatRequestOptions', thinking: false,
                    ...(systemPrompt ? {systemPrompt} : {})}
                };
                const update = event => {
                  generation.offset = Math.max(generation.offset, event.eventOffset || 0);
                  if (event.event.case === 'chat') generation.chatId = event.event.value.id || generation.chatId;
                  if (event.event.case === 'message') {
                    const value = event.event.value;
                    if (value.role === 3) {
                      generation.messageId = value.id || generation.messageId;
                      for (const block of value.blocks || []) {
                        if (block.content?.case === 'text') generation.blocks.set(block.id, block.content.value.content || '');
                      }
                    }
                  }
                  if (event.event.case === 'block') {
                    const block = event.event.value;
                    if (block.content?.case === 'text') {
                      const old = generation.blocks.get(block.id) || '';
                      generation.blocks.set(block.id, event.op === 2 ? old + (block.content.value.content || '') : (block.content.value.content || ''));
                      send({id, type: 'snapshot', text: [...generation.blocks.values()].join(''), chatId: generation.chatId, messageId: generation.messageId});
                    }
                  }
                  if (event.event.case !== 'block') send({id, type: 'progress', chatId: generation.chatId, messageId: generation.messageId});
                };
                for await (const event of client.chat(request, {signal: generation.controller.signal})) update(event);
                if (!generation.chatId || !generation.messageId) throw new Error('Kimi stream ended without a generation identity');
                let result = await client.getMessage({chatId: generation.chatId, messageId: generation.messageId});
                for (let attempt = 0; result.message?.status === 1 && attempt < 2; attempt++) {
                  for await (const event of client.resumeChat({chatId: generation.chatId, messageId: generation.messageId, eventOffset: generation.offset}, {signal: generation.controller.signal})) update(event);
                  result = await client.getMessage({chatId: generation.chatId, messageId: generation.messageId});
                }
                const finalMessage = result.message;
                if (finalMessage?.status !== 2) throw new Error('Kimi generation ended with status ' + (finalMessage?.status ?? 'unknown'));
                const finalText = (finalMessage.blocks || []).filter(block => block.content?.case === 'text').map(block => block.content.value.content || '').join('');
                send({id, type: 'snapshot', text: finalText, chatId: generation.chatId, messageId: generation.messageId});
                send({id, type: 'completed', chatId: generation.chatId, messageId: generation.messageId});
              } catch (error) {
                send({id, type: 'failed', message: String(error?.message || error), chatId: generation.chatId, messageId: generation.messageId});
              } finally {
                active.delete(id);
              }
            })();
            return true;
          };
          window.__oxKimiCancel = async id => {
            const generation = active.get(id);
            if (!generation) return false;
            generation.controller.abort();
            if (!generation.chatId || !generation.messageId) return false;
            const client = await service('kimi.gateway.chat.v1.ChatService');
            await client.cancelChat({chatId: generation.chatId, messageId: generation.messageId});
            const result = await client.getMessage({chatId: generation.chatId, messageId: generation.messageId});
            return result.message?.status === 3;
          };
        }
        return true;
        """#
}
