import Foundation

struct StreamOptions {
    var temperature: Double?
    var maxTokens: Int?
}

struct WebsiteAttachment {
    let name: String
    var mimeType = "image/png"
}

struct WebsiteProviderError: Error {
    enum Kind { case provider, network }
    init(_ message: String, kind: Kind = .provider) {}
}

enum Log {
    struct Logger {
        func info(_ message: String) {}
    }
    static let service = Logger()
}

@MainActor
enum WebsiteAttachmentTransfer {
    static var staged: [String] = []
    static func stage(_ attachments: [WebsiteAttachment], on page: Service.ServiceWebPage) async throws {
        staged = attachments.map(\.name)
    }
}

@MainActor
final class Service {
    final class ServiceWebPage {
        var navigationGeneration = 0
        var isReady = true
        var closed = false
        let logLabel = "test"
        var page: ServiceWebPage { self }
    }

    final class Manager {
        var modelConversations: [UUID: ModelConversation] = [:]
        var attached = true
        func isChatAttached(_ id: UUID) -> Bool { attached }
    }

    struct Definition {
        var continuation = true
        let repositoryID = "test"
        func action(_ id: String, includingStandard: Bool) -> String? {
            id != ModelServiceContract.resume || continuation ? id : nil
        }
    }

    enum Role { case modelGeneration }
    enum Owner { case model(UUID) }
    let domain = "example.com"
    let manager: Manager
    var definition = Definition()
    var pages: [ServiceWebPage] = []
    var calls: [(String, JSONValue)] = []
    var rejectContinuation = false

    init(manager: Manager = Manager()) { self.manager = manager }
    func loadManifest() async {}
    func resolvedAction(_ id: String, role: Role) async -> String? { id }
    func openOwnedPage(for action: String, owner: Owner) async throws -> ServiceWebPage {
        let page = ServiceWebPage()
        pages.append(page)
        return page
    }
    func closeOwnedPage(_ page: ServiceWebPage) { page.closed = true }
    func owns(_ page: ServiceWebPage) -> Bool { !page.closed }
    func invokeAction(_ action: String, args: JSONValue, role: Role, in page: ServiceWebPage) async -> Result<JSONValue, Error> {
        calls.append((action, args))
        if action == ModelServiceContract.resume && rejectContinuation {
            return .failure(WebsiteProviderError("Continuation failed after submission"))
        }
        return .success(.object(["generationId": .string("generation-\(calls.count)"), "submission": .string("uncertain")]))
    }
}

enum ModelServiceContract {
    static let start = "startModelGeneration"
    static let resume = "continueModelGeneration"
    static let read = "readModelGeneration"
    static let cancel = "cancelModelGeneration"
}

@main
struct ConversationTests {
    static func turn(_ role: String, _ text: String) -> JSONValue {
        .object(["role": .string(role), "text": .string(text)])
    }

    @MainActor static func main() async throws {
        let initial = [turn("system", "Instructions"), turn("user", "Hello")]
        let history = initial + [ModelConversationHistory.assistantTurn("Hello")]
        let next = history + [turn("user", "Continue")]
        let chatID = UUID()
        let options = StreamOptions()
        func checkout(_ service: Service, messages: [JSONValue] = initial, model: String = "default", options: StreamOptions = StreamOptions(), chat: UUID? = chatID) async throws -> (ModelConversation, ModelConversation.Turn) {
            try await ModelConversation.checkout(service: service, chatID: chat, modelID: model, options: options, messages: messages)
        }
        func complete(_ service: Service) async throws -> ModelConversation {
            let (conversation, turn) = try await checkout(service)
            let generation = try await conversation.start(turn: turn, attachments: [])
            conversation.finish(generation, history: history, chatID: chatID)
            return conversation
        }

        let service = Service()
        let first = try await complete(service)
        precondition(service.manager.modelConversations[chatID] === first)
        let (continued, newTurn) = try await checkout(service, messages: next)
        precondition(continued === first && service.pages.count == 1)
        precondition(newTurn.messages == [next.last!] && newTurn.previousGenerationID == "generation-1")
        let second = try await continued.start(turn: newTurn, attachments: [])
        precondition(service.calls.map(\.0) == [ModelServiceContract.start, ModelServiceContract.resume])
        precondition(service.calls[0].1.objectValue?["previousGenerationId"] == nil)
        precondition(service.calls[1].1.objectValue?["modelId"] == nil)
        precondition(service.calls[1].1.objectValue?["options"] == nil)
        precondition(service.calls[1].1.objectValue?["messages"] == .array([next.last!]))
        _ = try await continued.read(second, after: 3)
        precondition(service.calls.last?.0 == ModelServiceContract.read)
        await continued.cancelAndClose(second)
        precondition(service.calls.last?.0 == ModelServiceContract.cancel && service.pages[0].closed)
        precondition(service.manager.modelConversations.isEmpty)

        let freshOnly = Service()
        freshOnly.definition.continuation = false
        _ = try await complete(freshOnly)
        precondition(freshOnly.pages[0].closed && freshOnly.manager.modelConversations.isEmpty)
        let (fresh, fullTurn) = try await checkout(freshOnly, messages: next)
        precondition(fullTurn.previousGenerationID == nil && fullTurn.messages == next)
        _ = try await fresh.start(turn: fullTurn, attachments: [WebsiteAttachment(name: "earlier.png")])
        precondition(freshOnly.pages.count == 2 && freshOnly.calls.last?.0 == ModelServiceContract.start)
        precondition(WebsiteAttachmentTransfer.staged == ["earlier.png"])
        fresh.close()

        for reason in ["history", "system", "model", "temperature", "maxTokens", "page", "navigation", "closed", "capability", "service"] {
            let original = Service()
            let prior = try await complete(original)
            var current = original
            var messages = next
            var model = "default"
            var changedOptions = options
            switch reason {
            case "history": messages = [turn("user", "Summary"), next.last!]
            case "system": messages[0] = turn("system", "New instructions")
            case "model": model = "other"
            case "temperature": changedOptions.temperature = 0.5
            case "maxTokens": changedOptions.maxTokens = 512
            case "page": original.pages[0].isReady = false
            case "navigation": original.pages[0].navigationGeneration += 1
            case "closed": prior.close()
            case "capability": original.definition.continuation = false
            case "service": current = Service(manager: original.manager)
            default: preconditionFailure()
            }
            let (replacement, turn) = try await checkout(current, messages: messages, model: model, options: changedOptions)
            precondition(replacement !== prior && turn.previousGenerationID == nil && turn.messages == messages, reason)
            precondition(original.pages[0].closed, reason)
            replacement.close()
        }

        for detached in [false, true] {
            let service = Service()
            service.manager.attached = !detached
            let id: UUID? = detached ? chatID : nil
            let (conversation, turn) = try await checkout(service, chat: id)
            let generation = try await conversation.start(turn: turn, attachments: [])
            conversation.finish(generation, history: history, chatID: id)
            precondition(service.pages[0].closed && service.manager.modelConversations.isEmpty)
        }

        let uploads = Service()
        let fileHistory = history + [turn("user", "{\"uploaded_file\":\"old.png\"}"), turn("assistant", "Seen")]
        let fileTurn = turn("tool", "<ox_action_result>\n{\"content\":\"{\\\"uploaded_file\\\":\\\"new.png\\\"}\"}\n</ox_action_result>")
        let (uploadConversation, uploadStart) = try await checkout(uploads, messages: Array(fileHistory.dropLast()))
        let uploadGeneration = try await uploadConversation.start(turn: uploadStart, attachments: [WebsiteAttachment(name: "old.png")])
        uploadConversation.finish(uploadGeneration, history: fileHistory, chatID: chatID)
        let (uploadContinuation, uploadTurn) = try await checkout(uploads, messages: fileHistory + [fileTurn])
        _ = try await uploadContinuation.start(turn: uploadTurn, attachments: [WebsiteAttachment(name: "old.png"), WebsiteAttachment(name: "new.png")])
        precondition(WebsiteAttachmentTransfer.staged == ["new.png"])
        precondition(uploads.calls.last?.1.objectValue?["attachments"]?.arrayValue?.first?.objectValue?["id"] == .int(0))
        uploadContinuation.close()

        let failing = Service()
        _ = try await complete(failing)
        failing.rejectContinuation = true
        let (failure, failedTurn) = try await checkout(failing, messages: next)
        do {
            _ = try await failure.start(turn: failedTurn, attachments: [])
            preconditionFailure("Continuation should fail")
        } catch {
            await failure.cancelAndClose(nil)
        }
        precondition(failing.calls.map(\.0) == [ModelServiceContract.start, ModelServiceContract.resume])
        precondition(failing.pages.count == 1 && failing.pages[0].closed)
        precondition(failing.manager.modelConversations.isEmpty)
        print("Model conversation routing passed")
    }
}
