import Foundation
import WebKit

nonisolated private struct ClaudeWebsiteError: ProviderClientError {
    let message: String
    let failureKind: LLMFailureKind

    init(_ message: String, kind: LLMFailureKind = .provider) {
        self.message = message
        failureKind = kind
    }
}

nonisolated struct ClaudeWebsiteProvider: ProviderClient {
    let models: [ProviderModel]
    let id = "claude-web"
    let displayName = "Claude Website"
    let regions: Set<LLMRegion> = [.global]
    let website = URL(string: "https://claude.ai/")
    let usesAPIKey = false
    let supportsTools = true
    let subscriptionAccount: (any SubscriptionAccount)? = nil

    func websiteSessionIsAuthenticated() async throws -> Bool? {
        try await ClaudeWebGenerationSession.shared.isSignedIn()
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
                throw ClaudeWebsiteError("This Claude website model is unavailable")
            }
            guard requiredInputModalities(in: messages).isSubset(of: Set([.text])) else {
                throw ClaudeWebsiteError("Claude website supports text only", kind: .unsupportedInput)
            }
            guard options.temperature == nil else {
                throw ClaudeWebsiteError("Claude website does not support temperature")
            }
            let toolInstructions = WebsiteToolContract.instructions(tools)
            let instructions = [systemPrompt, toolInstructions].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            let prompt = try WebsiteProviderPrompt.prompt(messages: messages, toolInstructions: instructions, providerName: "Claude")
            let generationID = try await ClaudeWebGenerationSession.shared.start(prompt: prompt)
            var assembler = StreamAssembler(model: model, continuation: continuation)
            var cursor = 0
            var terminal = false

            do {
                assembler.start()
                while !terminal {
                    try Task.checkCancellation()
                    let update = try await ClaudeWebGenerationSession.shared.read(generationID, after: cursor)
                    guard update.nextCursor >= cursor,
                          update.nextCursor - cursor == update.events.count else {
                        throw ClaudeWebsiteError("Claude generation events are out of order")
                    }
                    cursor = update.nextCursor
                    for event in update.events {
                        guard !terminal else { throw ClaudeWebsiteError("Claude sent events after completion") }
                        switch event {
                        case .textSnapshot(let text):
                            if !WebsiteToolContract.isPossibleCallPrefix(text) {
                                assembler.textDelta(text)
                            }
                        case .completed:
                            terminal = true
                            await WebsiteAuthenticationCache.set(true, for: id)
                            let text = update.events.compactMap { event -> String? in
                                if case .textSnapshot(let value) = event { return value }
                                return nil
                            }.last ?? ""
                            if WebsiteToolContract.isPossibleCallPrefix(text) {
                                guard let call = try WebsiteToolContract.call(from: text, tools: tools) else {
                                    throw ClaudeWebsiteError("Claude returned an incomplete Ox Action call")
                                }
                                assembler.completeToolCall(call)
                                assembler.finish(reason: .toolUse, label: id, lines: cursor)
                            } else {
                                assembler.finish(reason: .stop, label: id, lines: cursor)
                            }
                        case .failed(let message, let kind):
                            throw ClaudeWebsiteError(message, kind: kind)
                        }
                    }
                }
            } catch {
                if !(error is CancellationError) {
                    await WebsiteAuthenticationCache.invalidate(id)
                }
                let cancelled = await ClaudeWebGenerationSession.shared.cancel(generationID)
                Log.agent.info("ClaudeWebsite.cancel generation=\(generationID) confirmed=\(cancelled)")
                throw error
            }
        }
    }
}

@MainActor
private final class ClaudeWebGenerationSession {
    static let shared = ClaudeWebGenerationSession()

    private final class Generation {
        let page: WebPage
        let prompt: String
        var events: [WebsiteGenerationEvent] = []
        var terminal = false
        var lastReconciliation = Date.distantPast
        let started = Date()

        init(page: WebPage, prompt: String) {
            self.page = page
            self.prompt = prompt
        }
    }

    private var generations: [UUID: Generation] = [:]
    private let website = URL(string: "https://claude.ai/new")!

    func isSignedIn() async throws -> Bool {
        let page = WebPage(configuration: IOSHost.shared.services.makeServicePageConfiguration(for: "claude.ai"))
        try await load(page)
        let value = try await page.callJavaScript(Self.authentication, arguments: [:], in: nil, contentWorld: .page)
        guard let result = value as? Bool else {
            throw ClaudeWebsiteError("Claude sign-in status could not be verified")
        }
        Log.agent.info("ClaudeWebsite.authentication signedIn=\(result)")
        return result
    }

    func start(prompt: String) async throws -> UUID {
        guard generations.isEmpty else { throw ClaudeWebsiteError("Claude website already has an active generation") }
        let id = UUID()
        let page = WebPage(configuration: IOSHost.shared.services.makeServicePageConfiguration(for: "claude.ai"))
        try await load(page)
        guard try await page.callJavaScript(Self.authentication, arguments: [:], in: nil, contentWorld: .page) as? Bool == true else {
            throw ClaudeWebsiteError("Sign in to Claude in Ox provider settings", kind: .authentication)
        }
        let generation = Generation(page: page, prompt: prompt)
        generations[id] = generation
        do {
            let value = try await page.callJavaScript(
                Self.submission,
                arguments: ["prompt": prompt],
                in: nil,
                contentWorld: .page
            )
            if let result = value as? [String: Any], result["status"] as? String == "failed" {
                generations.removeValue(forKey: id)
                throw ClaudeWebsiteError(result["message"] as? String ?? "Claude submit form is unavailable")
            }
            Log.agent.info("ClaudeWebsite.start generation=\(id) submission=uncertain")
            return id
        } catch let error as ClaudeWebsiteError {
            throw error
        } catch {
            Log.agent.warning("ClaudeWebsite.start generation=\(id) submission=uncertain error=\(error.localizedDescription)")
            return id
        }
    }

    func read(_ id: UUID, after cursor: Int) async throws -> WebsiteGenerationUpdate {
        guard let generation = generations[id] else {
            throw ClaudeWebsiteError("Claude generation is no longer available")
        }
        guard cursor >= 0, cursor <= generation.events.count else {
            throw ClaudeWebsiteError("Claude generation cursor is invalid")
        }
        let deadline = Date().addingTimeInterval(10)
        while cursor == generation.events.count && !generation.terminal && Date() < deadline {
            try Task.checkCancellation()
            if Date().timeIntervalSince(generation.started) > 2,
               Date().timeIntervalSince(generation.lastReconciliation) > 2 {
                generation.lastReconciliation = Date()
                await reconcile(id, generation: generation)
            }
            if Date().timeIntervalSince(generation.started) > 120 {
                generation.events.append(.failed("Claude did not confirm a completed response", .network))
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
        _ = generations.removeValue(forKey: id)
        return false
    }

    private func reconcile(_ id: UUID, generation: Generation) async {
        do {
            let value = try await generation.page.callJavaScript(
                Self.reconciliation,
                arguments: ["prompt": generation.prompt],
                in: nil,
                contentWorld: .page
            )
            guard generations[id] === generation, !generation.terminal,
                  let result = value as? [String: Any],
                  let status = result["status"] as? String else { return }
            if status == "failed" {
                generation.events.append(.failed(result["message"] as? String ?? "Claude conversation changed", .provider))
                generation.terminal = true
                return
            }
            guard status == "complete",
                  let chatID = result["chatId"] as? String,
                  let messageID = result["messageId"] as? String,
                  let text = result["text"] as? String,
                  !text.isEmpty else { return }
            generation.events.append(.textSnapshot(text))
            generation.events.append(.completed)
            generation.terminal = true
            Log.agent.info("ClaudeWebsite.recovered generation=\(id) chat=\(chatID) message=\(messageID)")
        } catch {
            Log.agent.warning("ClaudeWebsite.reconcile generation=\(id) error=\(error.localizedDescription)")
        }
    }

    private func load(_ page: WebPage) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for try await event in page.load(self.website) {
                    if event == .finished { return }
                }
                throw ClaudeWebsiteError("Claude website did not finish loading", kind: .network)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                throw ClaudeWebsiteError("Claude website loading timed out", kind: .network)
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private static let authentication = #"""
        const response = await fetch('/edge-api/bootstrap?statsig_hashing_algorithm=djb2&growthbook_format=sdk&cache_bust=1&include_system_prompts=false', {credentials: 'include', cache: 'no-store'});
        if (!response.ok || response.redirected) throw new Error('Claude session check HTTP ' + response.status);
        const body = await response.json();
        if (body.account === null) return false;
        if (typeof body.account?.uuid === 'string' && Array.isArray(body.account.memberships)) return true;
        throw new Error('Claude session response changed');
        """#

    private static let submission = #"""
        const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
        const visible = element => !!element && element.getClientRects().length > 0;
        const editor = () => {
          const element = document.querySelector('[data-testid="chat-input"][contenteditable="true"]');
          return visible(element) ? element : null;
        };
        try {
          if (location.pathname !== '/new') throw new Error('Claude is not on a fresh conversation');
          let input;
          for (let attempt = 0; attempt < 150 && !input; attempt++) { input = editor(); if (!input) await pause(100); }
          if (!input) throw new Error('Claude editor did not load');
          if (input.innerText.trim()) throw new Error('Claude has an existing draft; clear it on the website before retrying');
          input.focus();
          if (!document.execCommand('insertText', false, prompt)) throw new Error('Claude editor rejected the prompt');
          let button;
          for (let attempt = 0; attempt < 30 && !button; attempt++) {
            const candidate = document.querySelector('[data-testid="chat-input-send"]');
            if (editor()?.innerText.trim() === prompt.trim() && visible(candidate) && !candidate.disabled && candidate.getAttribute('aria-disabled') !== 'true') button = candidate;
            else await pause(100);
          }
          if (!button || editor()?.innerText.trim() !== prompt.trim()) throw new Error('Claude submit form is unavailable');
          button.click();
          return {status: 'submitted'};
        } catch (error) { return {status: 'failed', message: String(error?.message || error)}; }
        """#

    private static let reconciliation = #"""
        const path = location.pathname.match(/^\/chat\/([a-f0-9-]{36})$/);
        if (!path) return {status: 'pending'};
        const chatId = path[1];
        const request = async url => {
          const response = await fetch(url, {credentials: 'include', cache: 'no-store'});
          if (response.redirected || response.status !== 200) return null;
          return response.json();
        };
        const bootstrap = await request('/edge-api/bootstrap?statsig_hashing_algorithm=djb2&growthbook_format=sdk&cache_bust=1&include_system_prompts=false');
        if (!bootstrap?.account) return {status: 'failed', message: 'Claude session ended during generation'};
        const organizations = bootstrap.account.memberships?.map(value => value.organization?.uuid).filter(value => typeof value === 'string') || [];
        if (!organizations.length) throw new Error('Claude organization is unavailable');
        let conversation;
        for (const organization of organizations) {
          const path = '/api/organizations/' + encodeURIComponent(organization) + '/chat_conversations/' + encodeURIComponent(chatId) + '?tree=True&rendering_mode=messages&render_all_tools=true&include_inline_comparison=true&consistency=strong';
          const value = await request(path);
          if (value?.uuid === chatId && Array.isArray(value.chat_messages)) { conversation = value; break; }
        }
        if (!conversation) return {status: 'pending'};
        const messages = conversation.chat_messages;
        const messageText = value => typeof value?.text === 'string' && value.text ? value.text : (value?.content || []).filter(block => block.type === 'text' && typeof block.text === 'string').map(block => block.text).join('\n');
        const user = messages.find(value => value.sender === 'human' && messageText(value) === prompt);
        if (!user) return {status: 'failed', message: 'Claude conversation did not contain the submitted prompt'};
        const assistant = messages.find(value => value.sender === 'assistant' && value.parent_message_uuid === user.uuid);
        const text = messageText(assistant);
        if (!text || typeof assistant?.uuid !== 'string') return {status: 'pending'};
        const rendered = [...document.querySelectorAll('[data-testid="assistant-message"]')].at(-1);
        if (rendered?.getAttribute('data-is-streaming') !== 'false' || !rendered.innerText.trim()) return {status: 'pending'};
        return {status: 'complete', chatId, messageId: assistant.uuid, text};
        """#
}
