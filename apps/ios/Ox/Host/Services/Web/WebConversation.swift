import Foundation
import CryptoKit

/// One owner, one source, one page. Handles are process-local, never recovery checkpoints.
@MainActor
final class WebConversation {
    enum Owner: Equatable {
        case provider(UUID)
        case chat(UUID)
        case canvas(UUID)
        case client

        var logLabel: String {
            switch self {
            case .provider(let id): "provider:\(id.uuidString.prefix(8))"
            case .chat(let id): "chat:\(id.uuidString.prefix(8))"
            case .canvas(let id): "canvas:\(id.uuidString.prefix(8))"
            case .client: "client"
            }
        }
    }

    struct Opening {
        let owner: Owner
        let service: Service
    }

    let id: UUID
    let owner: Owner
    let service: Service
    let page: Service.ServiceWebPage
    private let navigationGeneration: Int
    private(set) var continuation = false
    private(set) var lastUsed = Date()
    private(set) var activeSince = Date()
    private(set) var isBusy = false
    private var isClosed = false
    private var conversationRef: String?
    private struct Submission {
        let nativeID: String
        var eventDigests: [Data] = []
        var text = ""
        var terminal = false
    }
    private var submissions: [String: Submission] = [:]
    private var latestSubmission: String?
    private var modelID: JSONValue?
    private var accountID: JSONValue?
    private var options: JSONValue?

    private init(id: UUID, service: Service, page: Service.ServiceWebPage, owner: Owner) {
        self.id = id
        self.service = service
        self.page = page
        self.owner = owner
        navigationGeneration = page.navigationGeneration
    }

    static func open(service: Service, owner: Owner, actionID: String) async throws -> WebConversation {
        service.manager.pruneWebConversations()
        // Reserve before any await, so scope/source cleanup also invalidates pending opens.
        let id = UUID()
        service.manager.openingWebConversations[id] = Opening(owner: owner, service: service)
        defer { service.manager.openingWebConversations.removeValue(forKey: id) }
        guard service.manager.webConversations.count + service.manager.openingWebConversations.count <= 12 else {
            throw WebsiteProviderError("Too many website conversations are open or opening")
        }
        guard let action = await service.resolvedAction(actionID, role: .modelGeneration) else {
            throw WebsiteProviderError("The website conversation service is unavailable")
        }
        try await requireAccess(service: service, action: action.definition)
        try Task.checkCancellation()
        guard service.manager.openingWebConversations[id] != nil else { throw CancellationError() }
        let page = try await service.openOwnedPage(for: action, owner: .conversation(id))
        if Task.isCancelled || service.manager.openingWebConversations[id] == nil {
            service.closeOwnedPage(page)
            throw CancellationError()
        }
        let conversation = WebConversation(id: id, service: service, page: page, owner: owner)
        service.manager.webConversations[conversation.id] = conversation
        Log.service.info("WebConversation.open domain=\(service.domain) source=\(service.definition.repositoryID ?? "unknown") owner=\(owner.logLabel) session=\(conversation.id) page=\(page.logLabel)")
        return conversation
    }

    private static func requireAccess(service: Service, action: Manifest.Action) async throws {
        let name = service.definition.qualifiedActionName(action.id)
        try await service.awaitAuthenticationAvailability(name: name)
        guard action.requireAuth else { return }
        await service.checkAccess(reason: .requireAuth)
        if service.auth.isSignedOut { await service.attemptSilentSignIn(reason: .requireAuth) }
        if service.auth.isUnavailable { throw Service.InvokeError.authUnavailable(name) }
        guard service.auth.isSignedIn else { throw Service.InvokeError.requiresAuth(name) }
    }

    func isExpired(at now: Date = Date()) -> Bool {
        isBusy ? now.timeIntervalSince(activeSince) > 3600 : now.timeIntervalSince(lastUsed) > 600
    }

    var isCurrent: Bool {
        !isClosed && !isExpired() && service.owns(page) && page.isReady && page.navigationGeneration == navigationGeneration
    }

    func checkPage() throws {
        guard isCurrent else {
            close()
            throw WebsiteProviderError("Website conversation interrupted or expired; the request was not resubmitted", kind: .network)
        }
    }

    func invoke(_ actionID: String, args: JSONValue) async throws -> JSONValue {
        try Task.checkCancellation()
        try checkPage()
        lastUsed = Date()
        if [ModelServiceContract.start, ModelServiceContract.resume].contains(actionID) {
            isBusy = true
            activeSince = Date()
        }
        let value = try await service.invokeAction(actionID, args: args, role: .modelGeneration, in: page).get()
        try checkPage()
        if actionID == ModelServiceContract.read,
           let terminal = value.objectValue?["events"]?.arrayValue?.last?.objectValue?["type"]?.stringValue,
           ["completed", "failed"].contains(terminal) { isBusy = false }
        return value
    }

    func call(_ args: JSONValue, attachments: [WebsiteAttachment] = []) async throws -> JSONValue {
        try WebConversationContract.validateInput(args, service: service.definition)
        try checkPage()
        switch args.objectValue?["operation"]?.stringValue {
        case "submit": return try await submit(args, attachments: attachments)
        case "read": return try await read(args)
        case "cancel": return try await cancel(args)
        default: throw WebsiteProviderError("Unknown website conversation operation")
        }
    }

    private func submit(_ args: JSONValue, attachments: [WebsiteAttachment]) async throws -> JSONValue {
        guard !isBusy, submissions.count < ModelServiceContract.maximumSubmissions, var fields = args.objectValue else {
            throw WebsiteProviderError("Website conversation is busy or its submission limit was reached")
        }
        guard let messages = fields["messages"]?.arrayValue, !messages.isEmpty,
              let last = messages.last?.objectValue,
              ["user", "tool"].contains(last["role"]?.stringValue ?? ""),
              last["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw WebsiteProviderError("Website submission requires a final nonempty user or tool message", kind: .unsupportedInput)
        }
        if let reference = fields["conversationRef"]?.stringValue {
            guard reference == id.uuidString, continuation, conversationRef != nil,
                  let latestSubmission, submissions[latestSubmission]?.terminal == true,
                  fields["modelId"] == modelID, fields["accountId"] == accountID, fields["options"] == options,
                  messages.allSatisfy({ ["user", "tool"].contains($0.objectValue?["role"]?.stringValue ?? "") }) else {
                throw WebsiteProviderError("Unknown, unsupported, or stale website conversation reference")
            }
            fields["conversationRef"] = conversationRef.map(JSONValue.string) ?? .null
        } else {
            guard submissions.isEmpty else { throw WebsiteProviderError("This page already owns a conversation") }
        }
        let refs = fields["attachments"]?.arrayValue ?? []
        guard refs.count == attachments.count,
              refs.enumerated().allSatisfy({ index, ref in
                  ref.objectValue?["id"]?.intValue == index
                    && ref.objectValue?["name"]?.stringValue == attachments[index].name
                    && ref.objectValue?["mimeType"]?.stringValue == attachments[index].mimeType
              }) else { throw WebsiteProviderError("Website attachments do not match the staged files", kind: .unsupportedInput) }
        // Admission is synchronous before any await; another submit cannot enter this page.
        isBusy = true
        activeSince = Date()
        do {
            guard let action = service.definition.action(WebConversationContract.actionID) else { throw WebsiteProviderError("Website conversation Action is unavailable") }
            try await Self.requireAccess(service: service, action: action)
            try await WebsiteAttachmentTransfer.stage(attachments, on: page.page)
            let value = try await invoke(WebConversationContract.actionID, args: .object(fields))
            guard var output = value.objectValue, output["operation"]?.stringValue == "submit",
                  let localID = output["submissionId"]?.stringValue,
                  let reference = output["conversationRef"]?.stringValue,
                  case .bool(let canContinue) = output["continuation"] else {
                throw WebsiteProviderError("Invalid website submission receipt; submission may have occurred")
            }
            if let conversationRef, conversationRef != reference {
                throw WebsiteProviderError("Website continuation changed conversation identity; submission may have occurred")
            }
            let handle = UUID().uuidString
            guard !submissions.values.contains(where: { $0.nativeID == localID }) else {
                throw WebsiteProviderError("Website reused a submission identity; submission may have occurred")
            }
            submissions[handle] = Submission(nativeID: localID)
            latestSubmission = handle
            conversationRef = reference
            modelID = fields["modelId"]
            accountID = fields["accountId"]
            options = fields["options"]
            continuation = canContinue
            output["submissionId"] = .string(handle)
            output["conversationRef"] = .string(id.uuidString)
            Log.service.info("WebConversation.submit session=\(id) submission=\(handle) certainty=\(output["submission"]?.stringValue ?? "uncertain") continuation=\(canContinue) turns=\(messages.count) files=\(attachments.count)")
            return .object(output)
        } catch {
            // A throw can follow a remote side effect. Invalidate, never retry on this page.
            close(reason: "submissionFailedOrUncertain")
            throw error
        }
    }

    private func submissionArguments(_ args: JSONValue) throws -> (String, [String: JSONValue]) {
        guard var fields = args.objectValue, let handle = fields["submissionId"]?.stringValue,
              let submission = submissions[handle] else { throw WebsiteProviderError("Unknown website submission") }
        fields["submissionId"] = .string(submission.nativeID)
        return (handle, fields)
    }

    private func read(_ args: JSONValue) async throws -> JSONValue {
        let (handle, fields) = try submissionArguments(args)
        guard let after = fields["after"]?.intValue, after <= (submissions[handle]?.eventDigests.count ?? 0) else {
            throw WebsiteProviderError("Website read cursor skips unobserved events")
        }
        do {
            let value = try await invoke(WebConversationContract.actionID, args: .object(fields))
            guard var output = value.objectValue, output["operation"]?.stringValue == "read",
                  output["conversationRef"]?.stringValue == conversationRef,
                  let events = output["events"]?.arrayValue, let after = fields["after"]?.intValue,
                  output["nextCursor"]?.intValue == after + events.count, events.count <= 1000,
                  var submission = submissions[handle], after <= submission.eventDigests.count,
                  after + events.count <= 4096 else {
                throw WebsiteProviderError("Invalid website event cursor or conversation identity")
            }
            for (index, event) in events.enumerated() {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let digest = Data(SHA256.hash(data: try encoder.encode(event)))
                let cursor = after + index
                if cursor < submission.eventDigests.count {
                    guard digest == submission.eventDigests[cursor] else { throw WebsiteProviderError("Website revised a previously read event") }
                    continue
                }
                guard !submission.terminal else { throw WebsiteProviderError("Website emitted events after completion") }
                switch event.objectValue?["type"]?.stringValue {
                case "text":
                    guard let text = event.objectValue?["text"]?.stringValue, text.hasPrefix(submission.text), text.utf8.count <= ModelServiceContract.maximumResponseBytes else {
                        throw WebsiteProviderError("Website revised published text or exceeded the response limit")
                    }
                    submission.text = text
                case "completed", "failed": submission.terminal = true
                default: throw WebsiteProviderError("Unknown website event")
                }
                submission.eventDigests.append(digest)
            }
            let retainedBytes = submissions.filter { $0.key != handle }.values.reduce(0) { $0 + $1.text.utf8.count }
            guard retainedBytes + submission.text.utf8.count <= ModelServiceContract.maximumRetainedResponseBytes else { throw WebsiteProviderError("Website response history exceeded the retained size limit") }
            submissions[handle] = submission
            if submission.terminal, handle == latestSubmission {
                isBusy = false
                if events.last?.objectValue?["type"]?.stringValue == "failed" { continuation = false }
            }
            output["conversationRef"] = .string(id.uuidString)
            Log.service.debug("WebConversation.read session=\(id) submission=\(handle) after=\(after) events=\(events.count) terminal=\(submission.terminal) bytes=\(submission.text.utf8.count)")
            return .object(output)
        } catch {
            close(reason: "readFailed")
            throw error
        }
    }

    private func cancel(_ args: JSONValue) async throws -> JSONValue {
        let (handle, fields) = try submissionArguments(args)
        let value = try await invoke(WebConversationContract.actionID, args: .object(fields))
        guard value.objectValue?["operation"]?.stringValue == "cancel" else {
            throw WebsiteProviderError("Invalid website cancellation receipt")
        }
        if value.objectValue?["status"]?.stringValue == "cancelled", handle == latestSubmission {
            isBusy = false
            continuation = false
        }
        Log.service.info("WebConversation.cancel session=\(id) submission=\(handle) status=\(value.objectValue?["status"]?.stringValue ?? "unknown")")
        return value
    }

    func ownsSubmission(_ handle: String) -> Bool { submissions[handle] != nil }

    func close(reason: String = "released") {
        guard !isClosed else { return }
        isClosed = true
        service.manager.webConversations.removeValue(forKey: id)
        submissions.removeAll()
        service.closeOwnedPage(page)
        Log.service.info("WebConversation.close domain=\(service.domain) owner=\(owner.logLabel) session=\(id) busy=\(isBusy) reason=\(reason)")
    }
}

extension ServiceManager {
    func pruneWebConversations(now: Date = Date()) {
        let expired = webConversations.values.filter { !$0.isCurrent || $0.isExpired(at: now) }
        expired.forEach { $0.close(reason: $0.isExpired(at: now) ? "expired" : "pageChanged") }
    }

    func closeWebConversations(owner: WebConversation.Owner? = nil, service: Service? = nil) {
        let conversations = webConversations.values.filter {
            (owner == nil || $0.owner == owner) && (service == nil || $0.service === service)
        }
        conversations.forEach { $0.close() }
        let openings = openingWebConversations.filter {
            (owner == nil || $0.value.owner == owner) && (service == nil || $0.value.service === service)
        }
        for (id, opening) in openings {
            openingWebConversations.removeValue(forKey: id)
            let pendingPages = opening.service.ownedPages.values.filter {
                if case .conversation(let pageOwner) = $0.owner { return pageOwner == id }
                return false
            }
            pendingPages.forEach { opening.service.closeOwnedPage($0.page) }
        }
    }

    func invokeConversation(service: Service, args: JSONValue, owner: WebConversation.Owner,
                            attachments: [WebsiteAttachment] = []) async throws -> JSONValue {
        try WebConversationContract.validateInput(args, service: service.definition)
        pruneWebConversations()
        let fields = args.objectValue ?? [:]
        let conversation: WebConversation
        let isNew = fields["operation"]?.stringValue == "submit" && fields["conversationRef"] == .null
        if isNew {
            conversation = try await WebConversation.open(service: service, owner: owner, actionID: WebConversationContract.actionID)
        } else {
            let reference = fields["conversationRef"]?.stringValue
            let submission = fields["submissionId"]?.stringValue
            guard let found = webConversations.values.first(where: {
                $0.owner == owner && $0.service === service
                    && (reference == $0.id.uuidString || submission.map($0.ownsSubmission) == true)
            }) else { throw WebsiteProviderError("Website conversation reference expired or belongs to another caller") }
            conversation = found
        }
        do { return try await conversation.call(args, attachments: attachments) }
        catch {
            if isNew { conversation.close() }
            throw error
        }
    }
}
