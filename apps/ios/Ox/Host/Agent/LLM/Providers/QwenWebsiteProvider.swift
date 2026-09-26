import Foundation
import WebKit

nonisolated private struct QwenWebsiteError: ProviderClientError {
    let message: String
    let failureKind: LLMFailureKind

    init(_ message: String, kind: LLMFailureKind = .provider) {
        self.message = message
        failureKind = kind
    }
}

nonisolated private struct QwenWebsiteModel: Decodable, Sendable {
    let id: String
    let name: String
}

nonisolated struct QwenWebsiteProvider: ProviderClient {
    let models: [ProviderModel]
    let id = "qwen-web"
    let displayName = "Qwen Website"
    let regions: Set<LLMRegion> = [.global]
    let website = URL(string: "https://chat.qwen.ai/")
    let usesAPIKey = false
    let supportsTools = true
    let subscriptionAccount: (any SubscriptionAccount)? = nil
    let canLoadModels = true

    static func model(id: String, name: String) -> ProviderModel {
        ProviderModel(id: "website:\(id)", providerModelID: id, displayName: name, maxTokens: 4_096, maxContext: 32_768, supportsTools: true)
    }

    func loadModels() async throws -> [ProviderModel] {
        try await QwenWebGenerationSession.shared.loadModels().map { Self.model(id: $0.id, name: $0.name) }
    }

    func websiteSessionIsAuthenticated() async throws -> Bool? {
        try await QwenWebGenerationSession.shared.isSignedIn()
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
                throw QwenWebsiteError("This Qwen website model is unavailable")
            }
            guard requiredInputModalities(in: messages).isSubset(of: Set([.text])) else {
                throw QwenWebsiteError("Qwen website supports text only", kind: .unsupportedInput)
            }
            guard options.temperature == nil else {
                throw QwenWebsiteError("Qwen website does not support temperature")
            }
            let toolInstructions = WebsiteToolContract.instructions(tools)
            let instructions = [systemPrompt, toolInstructions].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            let prompt = try WebsiteProviderPrompt.prompt(messages: messages, toolInstructions: instructions, providerName: "Qwen")
            let generationID = try await QwenWebGenerationSession.shared.start(
                prompt: prompt,
                modelID: model.id == "website-default" ? nil : model.wireID
            )
            var assembler = StreamAssembler(model: model, continuation: continuation)
            var cursor = 0
            var text = ""
            var terminal = false

            do {
                assembler.start()
                while !terminal {
                    try Task.checkCancellation()
                    let update = try await QwenWebGenerationSession.shared.read(generationID, after: cursor)
                    guard update.nextCursor >= cursor,
                          update.nextCursor - cursor == update.events.count else {
                        throw QwenWebsiteError("Qwen generation events are out of order")
                    }
                    cursor = update.nextCursor
                    for event in update.events {
                        guard !terminal else { throw QwenWebsiteError("Qwen sent events after completion") }
                        switch event {
                        case .textSnapshot(let snapshot):
                            text = snapshot
                        case .completed:
                            terminal = true
                            await WebsiteAuthenticationCache.set(true, for: id)
                            if WebsiteToolContract.isPossibleCallPrefix(text) {
                                guard let call = try WebsiteToolContract.call(from: text, tools: tools) else {
                                    throw QwenWebsiteError("Qwen returned an invalid Ox Action call")
                                }
                                assembler.completeToolCall(call)
                                assembler.finish(reason: .toolUse, label: id, lines: cursor)
                            } else {
                                assembler.textDelta(text)
                                assembler.finish(reason: .stop, label: id, lines: cursor)
                            }
                        case .failed(let message, let kind):
                            throw QwenWebsiteError(message, kind: kind)
                        }
                    }
                }
            } catch {
                if !(error is CancellationError) {
                    await WebsiteAuthenticationCache.invalidate(id)
                }
                let cancelled = await QwenWebGenerationSession.shared.cancel(generationID)
                Log.agent.info("QwenWebsite.cancel generation=\(generationID) confirmed=\(cancelled)")
                throw error
            }
        }
    }
}

@MainActor
private final class QwenWebGenerationSession: NSObject, WKScriptMessageHandler {
    static let shared = QwenWebGenerationSession()

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
    private let website = URL(string: "https://chat.qwen.ai/")!
    private let channel = "oxQwenGeneration"

    func isSignedIn() async throws -> Bool {
        let page = WebPage(configuration: IOSHost.shared.services.makeServicePageConfiguration(for: "chat.qwen.ai"))
        try await load(page)
        _ = try await page.callJavaScript(Self.bridge, arguments: [:], in: nil, contentWorld: .page)
        let result = try await page.callJavaScript(
            "return await window.__oxQwenSignedIn();",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        guard let signedIn = result as? Bool else {
            throw QwenWebsiteError("Qwen sign-in status could not be verified")
        }
        Log.agent.info("QwenWebsite.authentication signedIn=\(signedIn)")
        return signedIn
    }

    func loadModels() async throws -> [QwenWebsiteModel] {
        let page = WebPage(configuration: IOSHost.shared.services.makeServicePageConfiguration(for: "chat.qwen.ai"))
        try await load(page)
        _ = try await page.callJavaScript(Self.bridge, arguments: [:], in: nil, contentWorld: .page)
        let response = try await page.callJavaScript(
            "return await window.__oxQwenModels();",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        guard let json = response as? String,
              let data = json.data(using: .utf8),
              let models = try? JSONDecoder().decode([QwenWebsiteModel].self, from: data),
              !models.isEmpty, models.count <= 100,
              models.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 100 && !$0.name.isEmpty && $0.name.count <= 100 }),
              Set(models.map(\.id)).count == models.count else {
            throw QwenWebsiteError("Qwen returned an invalid model list")
        }
        Log.agent.info("QwenWebsite.models loaded count=\(models.count)")
        return models
    }

    func start(prompt: String, modelID: String?) async throws -> UUID {
        guard generations.isEmpty else { throw QwenWebsiteError("Qwen website already has an active generation") }
        let id = UUID()
        var configuration = IOSHost.shared.services.makeServicePageConfiguration(for: "chat.qwen.ai")
        configuration.userContentController.add(self, name: channel)
        let page = WebPage(configuration: configuration)
        generations[id] = Generation(page: page)
        do {
            try await load(page)
            try Task.checkCancellation()
            _ = try await page.callJavaScript(Self.bridge, arguments: [:], in: nil, contentWorld: .page)
            _ = try await page.callJavaScript(
                "return window.__oxQwenRun(id, prompt, modelID);",
                arguments: ["id": id.uuidString, "prompt": prompt, "modelID": modelID ?? ""],
                in: nil,
                contentWorld: .page
            )
            Log.agent.info("QwenWebsite.start generation=\(id) model=\(modelID ?? "website-default") submission=uncertain")
            return id
        } catch {
            generations.removeValue(forKey: id)
            WebsiteAuthenticationCache.invalidate("qwen-web")
            Log.agent.error("QwenWeb.start failed generation=\(id) error=\(error.localizedDescription)")
            throw QwenWebsiteError("Qwen website request could not start: \(error.localizedDescription)")
        }
    }

    func read(_ id: UUID, after cursor: Int) async throws -> WebsiteGenerationUpdate {
        guard let generation = generations[id] else {
            throw QwenWebsiteError("Qwen generation is no longer available")
        }
        guard cursor >= 0, cursor <= generation.events.count else {
            throw QwenWebsiteError("Qwen generation cursor is invalid")
        }
        let deadline = Date().addingTimeInterval(10)
        while cursor == generation.events.count && !generation.terminal && Date() < deadline {
            try Task.checkCancellation()
            if Date().timeIntervalSince(generation.lastEvent) > 120 {
                generation.events.append(.failed("Qwen stopped sending generation events", .network))
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
                "return await window.__oxQwenCancel(id);",
                arguments: ["id": id.uuidString],
                in: nil,
                contentWorld: .page
            )
            return value as? Bool == true
        } catch {
            Log.agent.warning("QwenWebsite.cancel generation=\(id) error=\(error.localizedDescription)")
            return false
        }
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard message.name == channel,
                  message.frameInfo.isMainFrame,
                  message.frameInfo.securityOrigin.host == "chat.qwen.ai",
                  let value = message.body as? [String: Any],
                  let idString = value["id"] as? String,
                  let id = UUID(uuidString: idString),
                  let generation = generations[id],
                  !generation.terminal else { return }
            generation.lastEvent = Date()
            if let chatID = value["chatId"] as? String, !chatID.isEmpty { generation.remoteChatID = chatID }
            if let messageID = value["messageId"] as? String, !messageID.isEmpty {
                if generation.remoteMessageID == nil {
                    Log.agent.info("QwenWeb.submitted generation=\(id) chat=\(generation.remoteChatID ?? "unknown") message=\(messageID)")
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
                let detail = value["message"] as? String ?? "Qwen generation failed"
                let kind: LLMFailureKind = detail.contains("Sign in to Qwen")
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
                throw QwenWebsiteError("Qwen website did not finish loading", kind: .network)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                throw QwenWebsiteError("Qwen website loading timed out", kind: .network)
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private static let bridge = #"""
        if (!window.__oxQwenRun) {
          const active = new Map();
          const send = value => window.webkit.messageHandlers.oxQwenGeneration.postMessage(value);
          const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
          const client = async () => {
            for (let attempt = 0; attempt < 100; attempt++) {
              const script = [...document.scripts].find(value => value.src.includes('/qwen-chat-fe/') && value.src.endsWith('/js/main.js'));
              if (script) {
                const module = await import(script.src);
                const requests = Object.values(module).filter(value => typeof value === 'function' && String(value).includes('Accept-Language') && String(value).includes('responseType') && String(value).includes('baseURL'));
                if (requests.length !== 1 || typeof module.dN !== 'function' || !String(module.dN).includes('/auths/')) throw new Error('Qwen page client changed');
                return {module, request: requests[0], identity: module.dN};
              }
              await pause(100);
            }
            throw new Error('Qwen request client is unavailable');
          };
          const checked = async (request, path, options) => {
            const result = await request(path, {...options, toast: false});
            if (result?.success !== true) throw new Error('Qwen request failed: ' + String(result?.data?.message || result?.data?.code || 'unexpected response'));
            return result.data;
          };
          window.__oxQwenSignedIn = async () => {
            const {identity} = await client();
            const result = await identity(false);
            if (result?.success === false && (result?.data?.code === 'Unauthorized' || result?.data?.message === '401 Unauthorized')) return false;
            if (result?.success === true && result.data) return true;
            throw new Error('Qwen sign-in status could not be verified: ' + String(result?.data?.code || result?.status || 'unknown response'));
          };
          window.__oxQwenModels = async () => {
            const {request} = await client();
            const result = await checked(request, '/models', {method: 'GET'});
            if (!Array.isArray(result?.data)) throw new Error('Qwen model list is unavailable');
            return JSON.stringify(result.data.filter(model => model?.info?.is_active !== false && model?.info?.meta?.chat_type?.includes('t2t'))
              .map(model => ({id: model.id, name: model.name})));
          };
          window.__oxQwenRun = (id, prompt, modelID) => {
            const generation = {chatId: '', responseId: '', text: '', canceled: false, requestSubmitted: false};
            active.set(id, generation);
            void (async () => {
              try {
                if (!await window.__oxQwenSignedIn()) throw new Error('Sign in to Qwen in Ox provider settings');
                if (generation.canceled) return;
                const {module, request} = await client();
                let modelId = modelID || '';
                for (let attempt = 0; attempt < 100 && !modelId; attempt++) {
                  const stores = Object.values(module).filter(value => typeof value === 'function' && typeof value.getState === 'function');
                  const selected = stores.map(value => value.getState()?.selectedModelIds).find(value => Array.isArray(value) && value.length);
                  modelId = typeof selected?.[0] === 'string' ? selected[0] : '';
                  if (!modelId) await pause(100);
                }
                if (!modelId) throw new Error('Select a Qwen text model on the website');
                if (generation.canceled) return;
                const created = await checked(request, '/chats/new', {method: 'POST', data: {chatId: '', models: [modelId], project_id: '', timestamp: Date.now(), chat_type: 't2t', chat_mode: 'normal'}});
                if (typeof created?.id !== 'string' || !created.id) throw new Error('Qwen did not return a conversation ID');
                if (generation.canceled) return;
                generation.chatId = created.id;
                send({id, type: 'progress', chatId: generation.chatId});
                const user = {id: null, fid: crypto.randomUUID(), parentId: null, parent_id: null, childrenIds: [], role: 'user', content: prompt, user_action: 'chat', timestamp: Math.floor(Date.now() / 1000), models: [modelId], model: '', chat_type: 't2t', sub_chat_type: 't2t', feature_config: {thinking_enabled: false, output_schema: 'phase', research_mode: 'normal'}, extra: {meta: {subChatType: 't2t'}}};
                const body = {stream: true, version: '2.1', incremental_output: true, chatId: generation.chatId, parentId: '', chat_id: generation.chatId, chat_mode: 'normal', model: modelId, parent_id: null, messages: [user], timestamp: Math.floor(Date.now() / 1000)};
                generation.requestSubmitted = true;
                const result = await request('/chat/completions', {method: 'post', responseType: 'stream', headers: {'X-Accel-Buffering': 'no', 'X-Request-Id': crypto.randomUUID()}, params: {chat_id: generation.chatId}, data: body});
                if (result?.success !== true || result.isStream !== true || !result.data?.getReader) throw new Error('Qwen did not start a completion stream');
                const reader = result.data.getReader();
                const decoder = new TextDecoder();
                let buffer = '';
                let done = false;
                const frameKeys = new Set();
                while (!done) {
                  const next = await reader.read();
                  if (next.done) break;
                  buffer = (buffer + decoder.decode(next.value, {stream: true})).replace(/\r\n/g, '\n');
                  let boundary;
                  while ((boundary = buffer.indexOf('\n\n')) >= 0) {
                    const event = buffer.slice(0, boundary);
                    buffer = buffer.slice(boundary + 2);
                    const data = event.split('\n').filter(line => line.startsWith('data:')).map(line => line.slice(5).trimStart()).join('\n');
                    if (data === '[DONE]') { done = true; break; }
                    if (!data) continue;
                    const frame = JSON.parse(data);
                    for (const key of Object.keys(frame)) frameKeys.add(key);
                    if (frame.error) throw new Error(String(frame.error.message || frame.error));
                    const createdResponse = frame['response.created'];
                    if (createdResponse?.response_id) {
                      generation.responseId = createdResponse.response_id;
                      send({id, type: 'progress', chatId: generation.chatId, messageId: generation.responseId});
                    }
                    if (frame['response.stopped']) throw new Error('Qwen stopped the response');
                    const delta = frame.choices?.[0]?.delta;
                    if (typeof delta?.content === 'string' && (!delta.phase || delta.phase === 'answer') && delta.role !== 'function') {
                      generation.text += delta.content;
                      send({id, type: 'snapshot', text: generation.text, chatId: generation.chatId, messageId: generation.responseId});
                    }
                  }
                }
                if (!generation.responseId) throw new Error('Qwen stream ended without a response ID; frames=' + [...frameKeys].join(','));
                let finalMessage;
                for (let attempt = 0; attempt < 20; attempt++) {
                  const chat = await checked(request, '/chats/' + generation.chatId, {method: 'GET'});
                  const messages = chat?.chat?.messages;
                  finalMessage = Array.isArray(messages) ? messages.find(value => value.role === 'assistant' && (value.id === generation.responseId || value.fid === generation.responseId)) : undefined;
                  if (finalMessage?.done === true) break;
                  await pause(250);
                }
                if (finalMessage?.done !== true) throw new Error('Qwen did not confirm completion; streamTerminal=' + done + '; frames=' + [...frameKeys].join(','));
                if (finalMessage.error) throw new Error('Qwen completed with an error');
                const finalText = typeof finalMessage.content === 'string' && finalMessage.content ? finalMessage.content : (finalMessage.content_list || []).filter(value => value.phase === 'answer').map(value => value.content || '').join('\n');
                if (typeof finalText !== 'string' || !finalText) throw new Error('Qwen completed without text');
                send({id, type: 'snapshot', text: finalText, chatId: generation.chatId, messageId: generation.responseId});
                send({id, type: 'completed', chatId: generation.chatId, messageId: generation.responseId});
              } catch (error) {
                send({id, type: 'failed', message: String(error?.message || error), chatId: generation.chatId, messageId: generation.responseId});
              } finally {
                active.delete(id);
              }
            })();
            return true;
          };
          window.__oxQwenCancel = async id => {
            const generation = active.get(id);
            if (!generation) return false;
            generation.canceled = true;
            if (!generation.requestSubmitted) return true;
            for (let attempt = 0; attempt < 50 && !generation.responseId && active.has(id); attempt++) await pause(100);
            if (!generation.chatId || !generation.responseId) return false;
            const {request} = await client();
            const result = await request('/chat/completions/stop', {method: 'post', params: {chat_id: generation.chatId}, data: {chat_id: generation.chatId, response_id: generation.responseId}, toast: false});
            return result?.success === true && result?.data?.status === true;
          };
        }
        return true;
        """#
}
