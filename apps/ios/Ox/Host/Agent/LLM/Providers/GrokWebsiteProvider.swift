import Foundation
import WebKit

nonisolated private struct GrokWebsiteError: ProviderClientError {
    let message: String
    let failureKind: LLMFailureKind

    init(_ message: String, kind: LLMFailureKind = .provider) {
        self.message = message
        failureKind = kind
    }
}

nonisolated struct GrokWebsiteProvider: ProviderClient {
    let models: [ProviderModel]
    let id = "grok-web"
    let displayName = "Grok Website"
    let regions: Set<LLMRegion> = [.global]
    let website = URL(string: "https://grok.com/")
    let usesAPIKey = false
    let supportsTools = true
    let subscriptionAccount: (any SubscriptionAccount)? = nil

    func websiteSessionIsAuthenticated() async throws -> Bool? {
        try await GrokWebGenerationSession.shared.isSignedIn()
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
                throw GrokWebsiteError("This Grok website model is unavailable")
            }
            guard requiredInputModalities(in: messages).isSubset(of: Set([.text])) else {
                throw GrokWebsiteError("Grok website supports text only", kind: .unsupportedInput)
            }
            guard options.temperature == nil else {
                throw GrokWebsiteError("Grok website does not support temperature")
            }
            let toolInstructions = WebsiteToolContract.instructions(tools)
            let instructions = [systemPrompt, toolInstructions].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            let prompt = try WebsiteProviderPrompt.prompt(messages: messages, toolInstructions: instructions, providerName: "Grok")
            let generationID = try await GrokWebGenerationSession.shared.start(prompt: prompt)
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
                    let update = try await GrokWebGenerationSession.shared.read(generationID, after: cursor)
                    guard update.nextCursor >= cursor,
                          update.nextCursor - cursor == update.events.count else {
                        throw GrokWebsiteError("Grok generation events are out of order")
                    }
                    cursor = update.nextCursor
                    for event in update.events {
                        guard !terminal else { throw GrokWebsiteError("Grok sent events after completion") }
                        switch event {
                        case .textSnapshot(let snapshot):
                            guard snapshot.hasPrefix(text) || emittedText.isEmpty else {
                                throw GrokWebsiteError("Grok revised streamed output; final text was not accepted")
                            }
                            text = snapshot
                            if !outputIsToolCall && WebsiteToolContract.isPossibleCallPrefix(snapshot) {
                                outputIsToolCall = snapshot.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(WebsiteToolContract.start)
                                continue
                            }
                            if outputIsToolCall { continue }
                            guard snapshot.hasPrefix(emittedText) else {
                                throw GrokWebsiteError("Grok revised streamed output; final text was not accepted")
                            }
                            let delta = String(snapshot.dropFirst(emittedText.count))
                            emittedText = snapshot
                            if !delta.isEmpty { assembler.textDelta(delta) }
                        case .completed:
                            terminal = true
                            await WebsiteAuthenticationCache.set(true, for: id)
                            if !outputIsToolCall && emittedText.isEmpty && WebsiteToolContract.isPossibleCallPrefix(text) {
                                throw GrokWebsiteError("Grok returned an incomplete Ox Action call")
                            }
                            if outputIsToolCall {
                                guard let call = try WebsiteToolContract.call(from: text, tools: tools) else {
                                    throw GrokWebsiteError("Grok returned an invalid Ox Action call")
                                }
                                assembler.completeToolCall(call)
                                assembler.finish(reason: .toolUse, label: id, lines: cursor)
                            } else {
                                assembler.finish(reason: .stop, label: id, lines: cursor)
                            }
                        case .failed(let message, let kind):
                            throw GrokWebsiteError(message, kind: kind)
                        }
                    }
                }
            } catch {
                if !(error is CancellationError) {
                    await WebsiteAuthenticationCache.invalidate(id)
                }
                let cancelled = await GrokWebGenerationSession.shared.cancel(generationID)
                Log.agent.info("GrokWebsite.cancel generation=\(generationID) confirmed=\(cancelled)")
                throw error
            }
        }
    }
}

@MainActor
private final class GrokWebGenerationSession: NSObject, WKScriptMessageHandler {
    static let shared = GrokWebGenerationSession()

    private final class Generation {
        let page: WebPage
        let prompt: String
        var events: [WebsiteGenerationEvent] = []
        var remoteChatID: String?
        var remoteMessageID: String?
        var terminal = false
        var lastEvent = Date()
        var lastReconciliation = Date.distantPast

        init(page: WebPage, prompt: String) {
            self.page = page
            self.prompt = prompt
        }
    }

    private var generations: [UUID: Generation] = [:]
    private let website = URL(string: "https://grok.com/")!
    private let channel = "oxGrokGeneration"

    func isSignedIn() async throws -> Bool {
        let page = WebPage(configuration: IOSHost.shared.services.makeServicePageConfiguration(for: "grok.com"))
        try await load(page)
        _ = try await page.callJavaScript(Self.bridge, arguments: [:], in: nil, contentWorld: .page)
        let result = try await page.callJavaScript(
            "return await window.__oxGrokSignedIn();",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        guard let signedIn = result as? Bool else {
            throw GrokWebsiteError("Grok sign-in status could not be verified")
        }
        Log.agent.info("GrokWebsite.authentication signedIn=\(signedIn)")
        return signedIn
    }

    func start(prompt: String) async throws -> UUID {
        guard generations.isEmpty else { throw GrokWebsiteError("Grok website already has an active generation") }
        let id = UUID()
        var configuration = IOSHost.shared.services.makeServicePageConfiguration(for: "grok.com")
        configuration.userContentController.add(self, name: channel)
        let page = WebPage(configuration: configuration)
        generations[id] = Generation(page: page, prompt: prompt)
        do {
            try await load(page)
            try Task.checkCancellation()
            _ = try await page.callJavaScript(Self.bridge, arguments: [:], in: nil, contentWorld: .page)
            _ = try await page.callJavaScript(
                "return window.__oxGrokRun(id, prompt);",
                arguments: ["id": id.uuidString, "prompt": prompt],
                in: nil,
                contentWorld: .page
            )
            Log.agent.info("GrokWebsite.start generation=\(id) submission=uncertain")
            return id
        } catch {
            generations.removeValue(forKey: id)
            WebsiteAuthenticationCache.invalidate("grok-web")
            Log.agent.error("GrokWeb.start failed generation=\(id) error=\(error.localizedDescription)")
            throw GrokWebsiteError("Grok website request could not start: \(error.localizedDescription)")
        }
    }

    func read(_ id: UUID, after cursor: Int) async throws -> WebsiteGenerationUpdate {
        guard let generation = generations[id] else {
            throw GrokWebsiteError("Grok generation is no longer available")
        }
        guard cursor >= 0, cursor <= generation.events.count else {
            throw GrokWebsiteError("Grok generation cursor is invalid")
        }
        let deadline = Date().addingTimeInterval(10)
        while cursor == generation.events.count && !generation.terminal && Date() < deadline {
            try Task.checkCancellation()
            if Date().timeIntervalSince(generation.lastEvent) > 5,
               Date().timeIntervalSince(generation.lastReconciliation) > 2 {
                generation.lastReconciliation = Date()
                await reconcile(id, generation: generation)
            }
            if Date().timeIntervalSince(generation.lastEvent) > 120 {
                generation.events.append(.failed("Grok stopped sending generation events", .network))
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

    private func reconcile(_ id: UUID, generation: Generation) async {
        do {
            let value = try await generation.page.callJavaScript(
                Self.reconciliation,
                arguments: ["prompt": generation.prompt, "chatId": generation.remoteChatID ?? ""],
                in: nil,
                contentWorld: .page
            )
            guard generations[id] === generation, !generation.terminal,
                  let result = value as? [String: Any],
                  let status = result["status"] as? String else { return }
            if status == "failed" {
                generation.events.append(.failed(result["message"] as? String ?? "Grok conversation changed", .provider))
                generation.terminal = true
                return
            }
            guard status == "complete",
                  let chatID = result["chatId"] as? String,
                  let messageID = result["messageId"] as? String,
                  let text = result["text"] as? String else { return }
            if let last = generation.events.last,
               case .textSnapshot(let streamed) = last,
               !text.hasPrefix(streamed) {
                generation.events.append(.failed("Grok revised streamed output", .provider))
                generation.terminal = true
                return
            }
            generation.remoteChatID = chatID
            generation.remoteMessageID = messageID
            generation.events.append(.textSnapshot(text))
            generation.events.append(.completed)
            generation.terminal = true
            Log.agent.info("GrokWebsite.recovered generation=\(id) chat=\(chatID) message=\(messageID)")
        } catch {
            Log.agent.warning("GrokWebsite.reconcile generation=\(id) error=\(error.localizedDescription)")
        }
    }

    func cancel(_ id: UUID) async -> Bool {
        guard let generation = generations.removeValue(forKey: id) else { return false }
        do {
            let value = try await generation.page.callJavaScript(
                "return await window.__oxGrokCancel(id);",
                arguments: ["id": id.uuidString],
                in: nil,
                contentWorld: .page
            )
            return value as? Bool == true
        } catch {
            Log.agent.warning("GrokWebsite.cancel generation=\(id) error=\(error.localizedDescription)")
            return false
        }
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard message.name == channel,
                  message.frameInfo.isMainFrame,
                  message.frameInfo.securityOrigin.host == "grok.com",
                  let value = message.body as? [String: Any],
                  let idString = value["id"] as? String,
                  let id = UUID(uuidString: idString),
                  let generation = generations[id],
                  !generation.terminal else { return }
            generation.lastEvent = Date()
            if let chatID = value["chatId"] as? String, !chatID.isEmpty { generation.remoteChatID = chatID }
            if let messageID = value["messageId"] as? String, !messageID.isEmpty {
                if generation.remoteMessageID == nil {
                    Log.agent.info("GrokWeb.submitted generation=\(id) chat=\(generation.remoteChatID ?? "unknown") message=\(messageID)")
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
                let detail = value["message"] as? String ?? "Grok generation failed"
                let kind: LLMFailureKind = detail.contains("Sign in to Grok")
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
                throw GrokWebsiteError("Grok website did not finish loading", kind: .network)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                throw GrokWebsiteError("Grok website loading timed out", kind: .network)
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private static let bridge = #"""
        if (!window.__oxGrokRun) {
          const active = new Map();
          const send = value => window.webkit.messageHandlers.oxGrokGeneration.postMessage(value);
          const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
          const visible = element => !!element && element.getClientRects().length > 0;
          const editor = () => [...document.querySelectorAll('[contenteditable="true"][role="textbox"]')].find(element => visible(element) && element.getAttribute('aria-disabled') !== 'true');
          window.__oxGrokSignedIn = async () => {
            const response = await fetch('/rest/user-settings', {credentials: 'include', cache: 'no-store'});
            if (response.redirected) throw new Error('Grok session check redirected');
            const body = await response.json();
            if (response.status === 401 && typeof body.code !== 'undefined' && typeof body.message === 'string') return false;
            if (response.status === 200 && typeof body.enableMemory === 'boolean' && typeof body.excludeFromTraining === 'boolean') return true;
            throw new Error('Grok session response changed');
          };
          const fail = (generation, error) => {
            if (generation.terminal || generation.canceled) return;
            generation.terminal = true;
            send({id: generation.id, type: 'failed', message: String(error?.message || error), chatId: generation.chatId, messageId: generation.responseId});
            active.delete(generation.id);
          };
          const originalFetch = window.fetch.bind(window);
          window.fetch = async function(input, init) {
            const url = typeof input === 'string' ? input : input?.url;
            const method = String(init?.method || input?.method || 'GET').toUpperCase();
            const generation = [...active.values()].find(value => value.submitting && !value.captured);
            const path = url ? new URL(url, location.href).pathname : '';
            const capture = generation && method === 'POST' && path === '/rest/app-chat/conversations/new';
            const response = await originalFetch(input, init);
            if (capture) {
              generation.captured = true;
              void observe(generation, response.clone());
            }
            return response;
          };
          const checked = async (path, options) => {
            const response = await fetch(path, {...options, credentials: 'include', cache: 'no-store'});
            if (!response.ok || response.redirected) throw new Error('Grok message read HTTP ' + response.status);
            return response.json();
          };
          const reconcile = async generation => {
            for (let attempt = 0; attempt < 40 && !generation.canceled; attempt++) {
              const chatId = generation.chatId || location.pathname.match(/^\/c\/([a-zA-Z0-9-]+)/)?.[1];
              if (!chatId) { await pause(250); continue; }
              generation.chatId = chatId;
              const root = '/rest/app-chat/conversations/' + encodeURIComponent(chatId);
              const index = await checked(root + '/response-node');
              if (!Array.isArray(index.responseNodes) || !Array.isArray(index.inflightResponses)) throw new Error('Grok message index changed');
              if (index.inflightResponses.length || !index.responseNodes.length) { await pause(250); continue; }
              if (index.responseNodes.length > 200 || index.responseNodes.some(value => typeof value.responseId !== 'string')) throw new Error('Grok message index is unsupported');
              const data = await checked(root + '/load-responses', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({responseIds: index.responseNodes.map(value => value.responseId)})});
              if (!Array.isArray(data.responses)) throw new Error('Grok message read changed');
              const messages = data.responses;
              const user = messages.find(value => value.sender === 'human' && value.message === generation.prompt);
              const assistants = messages.filter(value => value.sender === 'assistant' && typeof value.message === 'string' && value.message && value.partial !== true);
              const assistant = generation.responseId ? assistants.find(value => value.responseId === generation.responseId) : assistants.at(-1);
              if (!user || !assistant) { await pause(250); continue; }
              generation.responseId = assistant.responseId;
              if (!assistant.message.startsWith(generation.text)) throw new Error('Grok revised streamed output');
              if (assistant.message !== generation.text) {
                generation.text = assistant.message;
                send({id: generation.id, type: 'snapshot', text: generation.text, chatId, messageId: generation.responseId});
              }
              return;
            }
            throw new Error('Grok did not confirm a completed response');
          };
          const observe = async (generation, response) => {
            try {
              if (!response.ok || !response.body) throw new Error('Grok completion HTTP ' + response.status);
              const reader = response.body.getReader();
              const decoder = new TextDecoder();
              let buffer = '';
              const frame = line => {
                if (!line.trim()) return;
                const value = JSON.parse(line);
                if (value.error) throw new Error(String(value.error.message || value.error));
                const result = value.result || {};
                const response = result.response || result;
                if (typeof result.conversation?.conversationId === 'string') generation.chatId = result.conversation.conversationId;
                if (typeof response.modelResponse?.responseId === 'string') generation.responseId = response.modelResponse.responseId;
                const token = response.token;
                if (typeof token === 'string' && token && response.isThinking !== true && !response.messageStepId) {
                  generation.text += token;
                  send({id: generation.id, type: 'snapshot', text: generation.text, chatId: generation.chatId, messageId: generation.responseId});
                }
                if (response.error) throw new Error(String(response.error.message || response.error));
              };
              while (!generation.canceled) {
                const next = await reader.read();
                if (next.done) break;
                buffer += decoder.decode(next.value, {stream: true});
                if (buffer.length > 1_048_576) throw new Error('Grok stream frame exceeded limit');
                let boundary;
                while ((boundary = buffer.indexOf('\n')) >= 0) {
                  frame(buffer.slice(0, boundary));
                  buffer = buffer.slice(boundary + 1);
                }
              }
              if (generation.canceled) return;
              if (buffer.trim()) frame(buffer);
              await reconcile(generation);
              generation.terminal = true;
              send({id: generation.id, type: 'completed', chatId: generation.chatId, messageId: generation.responseId});
              active.delete(generation.id);
            } catch (error) { fail(generation, error); }
          };
          window.__oxGrokRun = (id, prompt) => {
            const generation = {id, prompt, text: '', chatId: '', responseId: '', submitting: false, captured: false, canceled: false, terminal: false};
            active.set(id, generation);
            void (async () => {
              try {
                if (!await window.__oxGrokSignedIn()) throw new Error('Sign in to Grok in Ox provider settings');
                if (location.pathname !== '/') throw new Error('Grok is not on a fresh conversation');
                let input;
                for (let attempt = 0; attempt < 80 && !input; attempt++) { input = editor(); if (!input) await pause(100); }
                const documentText = input?.editor?.state?.doc?.textContent;
                if (!input || !input.editor?.commands?.insertContent || typeof documentText !== 'string') throw new Error('Grok editor API is unavailable');
                if (documentText.trim() || input.textContent.trim()) throw new Error('Grok contains an existing draft');
                input.focus();
                if (!input.editor.commands.insertContent(prompt)) throw new Error('Grok editor rejected the prompt');
                for (let attempt = 0; attempt < 20 && input.editor.state.doc.textContent.trim() !== prompt.trim(); attempt++) await pause(100);
                if (input.editor.state.doc.textContent.trim() !== prompt.trim() || input.textContent.trim() !== prompt.trim()) throw new Error('Grok editor changed the prompt');
                const form = input.closest('form');
                let button;
                for (let attempt = 0; attempt < 30 && !button; attempt++) {
                  const candidate = document.querySelector('button[data-testid="chat-submit"][aria-label="Submit"]');
                  if (visible(candidate) && !candidate.disabled && candidate.getAttribute('aria-disabled') !== 'true') button = candidate;
                  else await pause(100);
                }
                if (!button || typeof form?.requestSubmit !== 'function') throw new Error('Grok submit form is unavailable');
                if (generation.canceled) return;
                generation.submitting = true;
                form.requestSubmit();
                for (let attempt = 0; attempt < 150 && !generation.captured && !generation.canceled; attempt++) await pause(100);
                if (!generation.captured && !generation.canceled) throw new Error('Grok submission outcome is uncertain; generation stream was not observed');
              } catch (error) { fail(generation, error); }
            })();
            return true;
          };
          window.__oxGrokCancel = id => {
            const generation = active.get(id);
            if (!generation) return false;
            generation.canceled = true;
            active.delete(id);
            if (!generation.submitting) return true;
            const stop = document.querySelector('button[aria-label="Stop"]');
            if (visible(stop)) stop.click();
            return false;
          };
        }
        return true;
        """#

    private static let reconciliation = #"""
        const path = location.pathname.match(/^\/c\/([a-zA-Z0-9-]+)$/);
        if (!path) return {status: 'pending'};
        const currentChatId = path[1];
        if (chatId && chatId !== currentChatId) return {status: 'failed', message: 'Grok conversation changed during generation'};
        const request = async (path, options) => {
          const response = await fetch(path, {...options, credentials: 'include', cache: 'no-store'});
          if (!response.ok || response.redirected) throw new Error('Grok message read HTTP ' + response.status);
          return response.json();
        };
        const root = '/rest/app-chat/conversations/' + encodeURIComponent(currentChatId);
        const index = await request(root + '/response-node');
        if (!Array.isArray(index.responseNodes) || !Array.isArray(index.inflightResponses)) throw new Error('Grok message index changed');
        if (index.responseNodes.length > 200 || index.responseNodes.some(value => typeof value.responseId !== 'string')) throw new Error('Grok message index is unsupported');
        if (index.inflightResponses.length || !index.responseNodes.length) return {status: 'pending'};
        const data = await request(root + '/load-responses', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({responseIds: index.responseNodes.map(value => value.responseId)})});
        if (!Array.isArray(data.responses)) throw new Error('Grok message read changed');
        const user = data.responses.find(value => value.sender === 'human' && value.message === prompt);
        if (!user) return {status: 'failed', message: 'Grok conversation did not contain the submitted prompt'};
        const assistants = data.responses.filter(value => value.sender === 'assistant' && typeof value.responseId === 'string' && typeof value.message === 'string');
        const assistant = assistants.at(-1);
        if (!assistant || assistant.partial === true) return {status: 'pending'};
        return {status: 'complete', chatId: currentChatId, messageId: assistant.responseId, text: assistant.message};
        """#
}
