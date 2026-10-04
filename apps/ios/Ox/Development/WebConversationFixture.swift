#if DEBUG && targetEnvironment(simulator)
import Foundation

/// End-to-end fixture: real WebKit pages and Action bridge, synthetic loopback website only.
@MainActor
enum WebConversationFixture {
    private static var started = false

    static func runIfRequested() async {
        guard !started, let raw = ProcessInfo.processInfo.environment["OX_WEB_CONVERSATION_FIXTURE_URL"],
              let url = URL(string: raw), url.scheme == "http", url.host == "127.0.0.1",
              let port = url.port, (8101...8105).contains(port), url.path == "/conversation-fixture" else { return }
        started = true
        let destination = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WebConversationFixture/result.json")
        var checks: [String] = []
        var failure: String?
        do { try await exercise(url: url, checks: &checks) }
        catch { failure = error.localizedDescription }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let result: JSONValue = .object([
                "passed": .bool(failure == nil), "checks": .array(checks.map(JSONValue.string)),
                "error": failure.map(JSONValue.string) ?? .null,
            ])
            try JSONEncoder().encode(result).write(to: destination, options: .atomic)
            Log.service.info("WebConversation.fixture passed=\(failure == nil) checks=\(checks.count) error=\(failure ?? "none")")
        } catch { Log.service.error("WebConversation.fixture receipt failed error=\(error.localizedDescription)") }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw WebsiteProviderError("Fixture: \(message)") }
    }

    private static func input(_ text: String, reference: String? = nil) -> JSONValue {
        .object([
            "operation": .string("submit"), "conversationRef": reference.map(JSONValue.string) ?? .null,
            "accountId": .null, "modelId": .string("website-default"),
            "messages": .array([.object(["role": .string("user"), "text": .string(text)])]),
            "attachments": .array([]), "options": .object(["temperature": .null, "maxTokens": .null]),
        ])
    }

    private static func read(_ receipt: JSONValue, after: Int = 0, wait: Int = 1000) -> JSONValue {
        .object(["operation": .string("read"), "submissionId": receipt.objectValue?["submissionId"] ?? .null,
                 "after": .int(after), "waitMilliseconds": .int(wait)])
    }

    private static func exercise(url: URL, checks: inout [String]) async throws {
        let manager = ServiceManager()
        var actions: [JSONValue] = []
        for id in [WebConversationContract.actionID, ModelServiceContract.list] {
            var action = ModelServiceContract.schemas[id]!.objectValue!
            action["id"] = .string(id)
            action["label"] = .string(id)
            action["baseUrl"] = .string(url.absoluteString)
            action["requireAuth"] = .bool(false)
            action["requireApproval"] = .bool(id == WebConversationContract.actionID)
            actions.append(.object(action))
        }
        let definition = try ServiceDefinition(manifest: .object([
            "domain": .string("127.0.0.1"), "name": .string("Conversation fixture"),
            "baseUrl": .string(url.absoluteString), "actions": .array(actions),
        ]))
        let service = Service(definition: definition, tint: 0, manager: manager)
        service.resolutionState = .idle(Service.Resolved(actions: script))
        service.setAuth(.notRequired)
        defer {
            manager.closeWebConversations()
            service.discardPages()
        }
        try require(definition.supportsModelGeneration && definition.supportsConversation, "capability discovery")
        try require(definition.action(WebConversationContract.actionID) != nil, "conversation hidden from tool discovery")
        checks.append("provider and tool capability discovery")

        let denied = await service.invokeAction(WebConversationContract.actionID, args: input("denied"), approve: { _, _ in false })
        if case .success = denied { throw WebsiteProviderError("Fixture: denied submission executed") }
        try require(manager.webConversations.isEmpty && service.ownedPages.isEmpty, "approval opened a page")
        checks.append("approval denial before page creation or submission")

        let (provider, turn) = try await WebModelContext.checkout(service: service, chatID: nil, modelID: "website-default",
            options: StreamOptions(), messages: [.object(["role": .string("user"), "text": .string("provider-first")])])
        defer { provider.close() }
        let generation = try await provider.start(turn: turn, attachments: [])
        var providerState = ModelServiceStreamState()
        try providerState.accept(try await provider.read(generation, after: 0))
        try require(providerState.completed && providerState.text == "provider-first", "provider adapter response")
        checks.append("provider start and streamed completion through conversation")

        let owner = WebConversation.Owner.chat(UUID())
        let file = WebsiteAttachment(name: "fixture.txt", mimeType: "text/plain", data: Data("fixture-file".utf8))
        var approvals = 0
        let native = NativeServiceOperations(id: UUID(), serviceManager: manager, bluetooth: BluetoothProvider(), presentations: .live,
            requireActive: {}, showBrowser: { _, _ in }, attachTransient: { _ in },
            importArtifact: { _, _ in throw WebsiteProviderError("Fixture: unexpected artifact import") }, choose: { _ in nil })
        let operations = ServiceOperations(serviceManager: manager, conversationOwner: owner,
            resolveConversationAttachments: { refs in refs.isEmpty ? [] : [file] },
            resolveService: { _ in service }, resolveAction: { _ in (service, WebConversationContract.actionID) },
            approve: { _, _, _, _, _ in approvals += 1 }, presentControl: { _, _ in nil },
            receiveArtifacts: { _ in throw WebsiteProviderError("Fixture: unexpected remote artifact") }, serviceChanged: { _ in },
            begin: { _, _, _ in UUID() }, finish: { _, _ in }, native: native)
        let qualifiedName = definition.qualifiedActionName(WebConversationContract.actionID)
        let receipt = try await operations.invokeAction(name: qualifiedName, args: input("service-first"), purpose: "fixture")!
        let reference = receipt.objectValue?["conversationRef"]?.stringValue
        try require(reference != nil && service.ownedPages.count == 2, "provider and tool shared a page")
        let first = try await operations.invokeAction(name: qualifiedName, args: read(receipt), purpose: "fixture")!
        try require(approvals == 1, "ordinary tool read repeated approval")
        try require(first.objectValue?["events"]?.arrayValue?.first?.objectValue?["text"]?.stringValue == "service-first", "tool inherited provider context")
        checks.append("provider and service page/context isolation")

        do {
            _ = try await manager.invokeConversation(service: service, args: read(receipt), owner: .chat(UUID()))
            throw WebsiteProviderError("Fixture: foreign owner read a submission")
        } catch let error as WebsiteProviderError { try require(!error.message.hasPrefix("Fixture:"), error.message) }
        let clientRead = await service.invokeAction(WebConversationContract.actionID, args: read(receipt))
        if case .success = clientRead { throw WebsiteProviderError("Fixture: Client borrowed a chat reference") }
        checks.append("cross-chat and Client handle rejection")

        let secondReceipt = try await operations.invokeAction(name: qualifiedName, args: input("service-second", reference: reference), purpose: "fixture")!
        let second = try await operations.invokeAction(name: qualifiedName, args: read(secondReceipt), purpose: "fixture")!
        try require(approvals == 2, "ordinary tool continuation/read approval routing")
        try require(second.objectValue?["events"]?.arrayValue?.first?.objectValue?["text"]?.stringValue == "service-first|service-second", "service continuation lost context")
        try require(service.ownedPages.count == 2, "continuation opened another page")
        let replayed = try await manager.invokeConversation(service: service, args: read(receipt), owner: owner)
        try require(first == replayed, "earlier submission changed after continuation")
        checks.append("same-page continuation and repeatable earlier receipt")

        var changed = input("changed", reference: reference).objectValue!
        changed["modelId"] = .string("another-model")
        do {
            _ = try await manager.invokeConversation(service: service, args: .object(changed), owner: owner)
            throw WebsiteProviderError("Fixture: continuation changed model")
        } catch let error as WebsiteProviderError { try require(!error.message.hasPrefix("Fixture:"), error.message) }
        changed = input("changed-account", reference: reference).objectValue!
        changed["accountId"] = .string("another-workspace")
        do {
            _ = try await manager.invokeConversation(service: service, args: .object(changed), owner: owner)
            throw WebsiteProviderError("Fixture: continuation changed account")
        } catch let error as WebsiteProviderError { try require(!error.message.hasPrefix("Fixture:"), error.message) }
        checks.append("model and account changes rejected before continuation")

        let resumed = try await provider.start(turn: .init(previousGenerationID: generation.id,
            messages: [.object(["role": .string("user"), "text": .string("provider-second")])]), attachments: [])
        var resumedState = ModelServiceStreamState()
        try resumedState.accept(try await provider.read(resumed, after: 0))
        try require(resumedState.text == "provider-first|provider-second", "provider continuation contaminated")
        checks.append("provider continuation isolated from service continuation")

        let clientReceipt = try await service.invokeAction(WebConversationContract.actionID, args: input("client-first"), approve: { _, _ in true }).get()
        let clientResult = try await service.invokeAction(WebConversationContract.actionID, args: read(clientReceipt), approve: { _, _ in
            throwawayApprovalCount += 1
            return false
        }).get()
        try require(clientResult.objectValue?["nextCursor"]?.intValue == 2 && throwawayApprovalCount == 0, "reading requested another approval")
        checks.append("generic Client routing and read without duplicate approval")

        var upload = input("file").objectValue!
        upload["attachments"] = .array([.object(["id": .int(0), "name": .string(file.name), "mimeType": .string(file.mimeType)])])
        let uploaded = try await operations.invokeAction(name: qualifiedName, args: .object(upload), purpose: "fixture")!
        let uploadedResult = try await manager.invokeConversation(service: service, args: read(uploaded), owner: owner)
        try require(uploadedResult.objectValue?["events"]?.arrayValue?.first?.objectValue?["text"]?.stringValue == "file|fixture-file", "tool did not stage File bytes")
        try require(uploadedResult.objectValue?["events"]?.arrayValue?.last?.objectValue?["result"]?.objectValue?["files"]?.arrayValue?.count == 1, "generated file metadata lost")
        let (fileProvider, fileTurn) = try await WebModelContext.checkout(service: service, chatID: nil, modelID: "website-default",
            options: StreamOptions(), messages: [.object(["role": .string("user"), "text": .string("file")])])
        defer { fileProvider.close() }
        let fileGeneration = try await fileProvider.start(turn: fileTurn, attachments: [file])
        var fileState = ModelServiceStreamState()
        try fileState.accept(try await fileProvider.read(fileGeneration, after: 0))
        try require(fileState.text == "file|fixture-file", "provider did not stage File bytes")
        checks.append("provider and service attachment bytes; generated file references")

        let slow = try await manager.invokeConversation(service: service, args: input("slow"), owner: .canvas(UUID()))
        let slowConversation = manager.webConversations.values.first { $0.ownsSubmission(slow.objectValue!["submissionId"]!.stringValue!) }!
        let slowOwner = slowConversation.owner
        do {
            _ = try await manager.invokeConversation(service: service, args: input("busy", reference: slow.objectValue?["conversationRef"]?.stringValue), owner: slowOwner)
            throw WebsiteProviderError("Fixture: busy conversation accepted input")
        } catch let error as WebsiteProviderError { try require(!error.message.hasPrefix("Fixture:"), error.message) }
        let cancel: JSONValue = .object(["operation": .string("cancel"), "submissionId": slow.objectValue!["submissionId"]!])
        async let waiting = manager.invokeConversation(service: service, args: read(slow), owner: slowOwner)
        try await Task.sleep(for: .milliseconds(50))
        let requested = try await manager.invokeConversation(service: service, args: cancel, owner: slowOwner)
        try require(requested.objectValue?["status"]?.stringValue == "requested" && slowConversation.isBusy, "unconfirmed cancellation treated as stopped")
        let cancelled = try await manager.invokeConversation(service: service, args: cancel, owner: slowOwner)
        try require(cancelled.objectValue?["status"]?.stringValue == "cancelled", "confirmed cancellation missing")
        let stopped = try await waiting
        try require(stopped.objectValue?["events"]?.arrayValue?.last?.objectValue?["type"]?.stringValue == "failed", "waiting read did not observe cancellation")
        checks.append("busy rejection and cancellation while a read waits")

        let before = manager.webConversations.count
        do {
            _ = try await manager.invokeConversation(service: service, args: input("uncertain-throw"), owner: owner)
            throw WebsiteProviderError("Fixture: uncertain throw was ignored")
        } catch let error as WebsiteProviderError { try require(!error.message.hasPrefix("Fixture:"), error.message) }
        catch { /* The Action bridge wraps JavaScript failures. */ }
        try require(manager.webConversations.count == before, "uncertain submission retained an unusable page")
        checks.append("uncertain submission invalidated without automatic retry")

        let corrupt = try await manager.invokeConversation(service: service, args: input("revised-event"), owner: owner)
        _ = try await manager.invokeConversation(service: service, args: read(corrupt), owner: owner)
        do {
            _ = try await manager.invokeConversation(service: service, args: read(corrupt), owner: owner)
            throw WebsiteProviderError("Fixture: revised terminal event accepted")
        } catch let error as WebsiteProviderError { try require(!error.message.hasPrefix("Fixture:"), error.message) }
        checks.append("changed replay event rejected and page invalidated")

        manager.closeWebConversations(owner: owner)
        do {
            _ = try await manager.invokeConversation(service: service, args: read(receipt), owner: owner)
            throw WebsiteProviderError("Fixture: closed handle reopened work")
        } catch let error as WebsiteProviderError { try require(!error.message.hasPrefix("Fixture:"), error.message) }
        checks.append("scope cleanup invalidates handles without resubmission")
        manager.pruneWebConversations(now: .distantFuture)
        try require(manager.webConversations.isEmpty && service.ownedPages.isEmpty, "idle sessions did not expire")
        checks.append("idle page eviction without reopening or resubmitting")

        let delayedURL = URL(string: url.absoluteString + "?slow-load=1")!
        var delayedManifest = definition.manifest.objectValue!
        delayedManifest["baseUrl"] = .string(delayedURL.absoluteString)
        delayedManifest["actions"] = .array(actions.map { value in
            var fields = value.objectValue!
            fields["baseUrl"] = .string(delayedURL.absoluteString)
            return .object(fields)
        })
        let delayedService = Service(definition: try ServiceDefinition(manifest: .object(delayedManifest)), tint: 0, manager: manager)
        delayedService.resolutionState = .idle(Service.Resolved(actions: script))
        delayedService.setAuth(.notRequired)
        defer { delayedService.discardPages() }
        let pendingOwner = WebConversation.Owner.canvas(UUID())
        let opening = Task { try await manager.invokeConversation(service: delayedService, args: input("closed-during-open"), owner: pendingOwner) }
        try await Task.sleep(for: .milliseconds(100))
        try require(!manager.openingWebConversations.isEmpty, "pending open was not reserved")
        manager.closeWebConversations(owner: pendingOwner)
        if case .success = await opening.result { throw WebsiteProviderError("Fixture: closed scope admitted pending submission") }
        try require(manager.openingWebConversations.isEmpty && delayedService.ownedPages.isEmpty, "closed scope leaked a pending page")
        checks.append("scope cleanup cancels an in-flight page open before submission")

        var capacity: [WebConversation] = []
        for _ in 0..<12 { capacity.append(try await WebConversation.open(service: service, owner: .client, actionID: WebConversationContract.actionID)) }
        do {
            _ = try await WebConversation.open(service: service, owner: .client, actionID: WebConversationContract.actionID)
            throw WebsiteProviderError("Fixture: thirteenth page opened")
        } catch let error as WebsiteProviderError { try require(!error.message.hasPrefix("Fixture:"), error.message) }
        try require(manager.webConversations.count == 12 && manager.openingWebConversations.isEmpty, "page capacity reservation leaked")
        checks.append("twelve-page bound and failed admission reservation cleanup")
        let interrupted = try await capacity[0].call(input("source-change"))
        service.discardPages()
        try require(manager.webConversations.isEmpty && service.ownedPages.isEmpty, "source invalidation retained owned pages")
        do {
            _ = try await manager.invokeConversation(service: service, args: read(interrupted), owner: .client)
            throw WebsiteProviderError("Fixture: invalidated page resumed a submission")
        } catch let error as WebsiteProviderError { try require(!error.message.hasPrefix("Fixture:"), error.message) }
        checks.append("source/page invalidation releases sessions and rejects old handles")

        var legacyManifest = definition.manifest.objectValue!
        legacyManifest["actions"] = .array(ModelServiceContract.actionIDs.sorted().map { id in
            var fields = ModelServiceContract.schemas[id]!.objectValue!
            fields["id"] = .string(id)
            fields["label"] = .string(id)
            fields["requireAuth"] = .bool(false)
            fields["requireApproval"] = .bool(false)
            return .object(fields)
        })
        let legacyService = Service(definition: try ServiceDefinition(manifest: .object(legacyManifest)), tint: 0, manager: manager)
        legacyService.resolutionState = .idle(Service.Resolved(actions: script))
        legacyService.setAuth(.notRequired)
        defer { legacyService.discardPages() }
        try require(!legacyService.definition.supportsConversation && legacyService.definition.supportsModelGeneration, "legacy capability detection")
        let (legacy, legacyTurn) = try await WebModelContext.checkout(service: legacyService, chatID: nil, modelID: "website-default",
            options: StreamOptions(), messages: [.object(["role": .string("user"), "text": .string("legacy-first")])])
        defer { legacy.close() }
        let legacyFirst = try await legacy.start(turn: legacyTurn, attachments: [])
        var legacyState = ModelServiceStreamState()
        try legacyState.accept(try await legacy.read(legacyFirst, after: 0))
        try require(legacyState.completed && legacyState.text == "legacy-first", "legacy start/read contract changed")
        let legacySecond = try await legacy.start(turn: .init(previousGenerationID: legacyFirst.id,
            messages: [.object(["role": .string("user"), "text": .string("legacy-second")])]), attachments: [])
        var legacyContinuation = ModelServiceStreamState()
        try legacyContinuation.accept(try await legacy.read(legacySecond, after: 0))
        try require(legacyContinuation.text == "legacy-first|legacy-second" && legacyService.ownedPages.count == 1, "legacy continuation changed")
        let legacySlow = try await legacy.start(turn: .init(previousGenerationID: legacySecond.id,
            messages: [.object(["role": .string("user"), "text": .string("slow")])]), attachments: [])
        await legacy.cancelAndClose(legacySlow)
        try require(manager.webConversations.isEmpty && legacyService.ownedPages.isEmpty, "legacy cancellation leaked a page")
        checks.append("legacy start/read/continuation/cancel compatibility on shared page lifecycle")
    }

    private static var throwawayApprovalCount = 0

    private static let script = #"""
    window.ox.install(({action}) => {
      const reference = crypto.randomUUID(), history = [], submissions = new Map();
      let latest;
      action('listModels', {async invoke() { return {models: [{id: 'website-default', name: 'Fixture', input: ['text'], contextTokens: null, outputTokens: null, streaming: true, cancellation: true, options: []}]}; }});
      const conversation = {async invoke(args) {
        if (args.operation === 'submit') {
          if (args.conversationRef !== null && args.conversationRef !== reference) throw Error('Unknown conversation');
          const text = args.messages.map(message => message.text).join('|');
          let suffix = '';
          if (args.attachments.length) {
            const files = window.__oxWebsiteFiles;
            if (!files || files.length !== args.attachments.length || files[0].name !== args.attachments[0].name || files[0].type !== args.attachments[0].mimeType) throw Error('File metadata mismatch');
            suffix = '|' + await files[0].text();
          }
          history.push(text + suffix);
          await fetch('/submit', {method: 'POST', body: text}); // Synthetic effect counted by the fixture server.
          if (text === 'uncertain-throw') throw Error('Submission may have occurred');
          const id = crypto.randomUUID();
          const state = {events: [], cancels: 0, reads: 0, text, modelId: args.modelId, options: args.options};
          submissions.set(id, state);
          latest = id;
          if (text !== 'slow') setTimeout(() => state.events.push({type: 'text', text: history.join('|')}, {type: 'completed', result: {url: null, files: text === 'file' ? [{id: 'fixture-file', name: 'fixture.txt', kind: 'file', mimeType: 'text/plain', sizeBytes: 12, url: null, thumbnailUrl: null, width: null, height: null, pageCount: null, tokenCount: null, source: 'generated', downloadable: false}] : []}}), 30);
          return {operation: 'submit', submissionId: id, conversationRef: reference, submission: 'uncertain', continuation: true, url: null};
        }
        const state = submissions.get(args.submissionId);
        if (!state) throw Error('Unknown submission');
        if (args.operation === 'cancel') {
          if (state.events.length) return {operation: 'cancel', status: 'completed'};
          if (++state.cancels === 1) return {operation: 'cancel', status: 'requested'};
          state.events.push({type: 'failed', message: 'Cancelled fixture', kind: 'provider'});
          return {operation: 'cancel', status: 'cancelled'};
        }
        if (args.operation !== 'read') throw Error('Unknown operation');
        const deadline = Date.now() + args.waitMilliseconds;
        while (args.after === state.events.length && Date.now() < deadline && !state.events.length) await new Promise(resolve => setTimeout(resolve, 10));
        const events = state.events.slice(args.after);
        if (state.text === 'revised-event' && ++state.reads > 1) events[0] = {type: 'text', text: 'changed'};
        return {operation: 'read', conversationRef: reference, url: null, nextCursor: args.after + events.length, events};
      }};
      action('conversation', conversation);
      action('startModelGeneration', {async invoke(args) {
        const receipt = await conversation.invoke({...args, operation: 'submit', conversationRef: null, accountId: null});
        return {generationId: receipt.submissionId, submission: receipt.submission};
      }});
      action('continueModelGeneration', {async invoke(args) {
        const previous = submissions.get(args.previousGenerationId);
        if (!previous || args.previousGenerationId !== latest || previous.events.at(-1)?.type !== 'completed') throw Error('Cannot continue generation');
        const receipt = await conversation.invoke({...args, operation: 'submit', conversationRef: reference, accountId: null, modelId: previous.modelId, options: previous.options});
        return {generationId: receipt.submissionId, submission: receipt.submission};
      }});
      action('readModelGeneration', {async invoke(args) {
        const result = await conversation.invoke({...args, operation: 'read', submissionId: args.generationId});
        return {nextCursor: result.nextCursor, events: result.events.map(event => event.type === 'completed' ? {type: 'completed'} : event)};
      }});
      action('cancelModelGeneration', {async invoke(args) {
        const result = await conversation.invoke({operation: 'cancel', submissionId: args.generationId});
        return {status: result.status};
      }});
    });
    """#
}
#endif
