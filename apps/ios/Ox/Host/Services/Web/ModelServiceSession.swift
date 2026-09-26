import Foundation

@MainActor
final class ModelServiceSession {
    nonisolated struct Model: Decodable, Sendable {
        let id: String
        let name: String
        let input: Set<ProviderModelModality>
        let contextTokens: Int?
        let outputTokens: Int?
        let streaming: Bool
        let cancellation: Bool
        let options: Set<String>

        var model: ProviderModel {
            WebServiceModelProvider.model(id: id, name: name, input: input, contextTokens: contextTokens, outputTokens: outputTokens)
        }
    }

    private enum State {
        case ready
        case starting
        case running(String, Date)
        case closed
    }

    private static var activeDomains: Set<String> = []
    private let service: Service
    private let page: Service.ServiceWebPage
    private let navigationGeneration: Int
    private var state = State.ready

    private init(service: Service, page: Service.ServiceWebPage) {
        self.service = service
        self.page = page
        navigationGeneration = page.navigationGeneration
    }

    private static func service(domain: String) throws -> Service {
        guard let service = IOSHost.shared.services.service(domain: domain), service.definition.supportsModelGeneration else {
            throw WebsiteProviderError("The selected model service is unavailable. Resolve its service source or choose another model.")
        }
        return service
    }

    static func isSignedIn(domain: String) async throws -> Bool {
        let service = try service(domain: domain)
        let state = await service.checkAccess(policy: .current, reason: .modelSignIn)
        guard state != .unknown else { throw WebsiteProviderError("Model service sign-in could not be verified", kind: .authentication) }
        return state.isAuthenticated || state == .notRequired
    }

    static func loadModels(domain: String) async throws -> [Model] {
        let service = try service(domain: domain)
        return try decodeModels(try await service.invokeAction(ModelServiceContract.list, args: .object([:]), role: .modelGeneration).get())
    }

    private static func decodeModels(_ value: JSONValue) throws -> [Model] {
        struct Response: Decodable { let models: [Model] }
        let response = try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(value))
        guard !response.models.isEmpty, response.models.count <= 100,
              response.models.contains(where: { $0.id == "website-default" }),
              Set(response.models.map(\.id)).count == response.models.count,
              response.models.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 100 && !$0.name.isEmpty && $0.name.count <= 100 && $0.input.contains(.text) && ($0.contextTokens ?? 1) > 0 && ($0.outputTokens ?? 1) > 0 }) else {
            throw WebsiteProviderError("Model service returned an invalid model list")
        }
        return response.models
    }

    static func open(domain: String) async throws -> ModelServiceSession {
        let service = try service(domain: domain)
        guard activeDomains.count < 5, activeDomains.insert(domain).inserted else {
            throw WebsiteProviderError("Model service already has an active generation or the generation limit was reached")
        }
        do {
            guard let action = await service.resolvedAction(ModelServiceContract.start, role: .modelGeneration) else {
                throw WebsiteProviderError("Model service source is unavailable")
            }
            let page = try await service.openOwnedPage(for: action, owner: .model(UUID()))
            if Task.isCancelled {
                service.closeOwnedPage(page)
                throw CancellationError()
            }
            Log.service.info("ModelService.open domain=\(domain) source=\(service.definition.repositoryID ?? "unknown") page=\(page.logLabel)")
            return ModelServiceSession(service: service, page: page)
        } catch {
            activeDomains.remove(domain)
            throw error
        }
    }

    func start(model: ProviderModel, input: WebsiteProviderInput, options: StreamOptions, modalities: Set<ProviderModelModality>) async throws {
        guard case .ready = state else { throw WebsiteProviderError("Model generation has already started") }
        let available = try Self.decodeModels(try await invoke(ModelServiceContract.list, .object([:])))
        guard let selected = available.first(where: { $0.id == model.wireID }), modalities.isSubset(of: selected.input) else {
            throw WebsiteProviderError("The selected model or input is unavailable", kind: .unsupportedInput)
        }
        guard options.temperature == nil || selected.options.contains("temperature"),
              options.maxTokens == nil || selected.options.contains("maxTokens") else {
            throw WebsiteProviderError("The selected website model does not support these generation options")
        }
        try await WebsiteAttachmentTransfer.stage(input.attachments, on: page.page)
        try checkPage()
        state = .starting
        let value = try await invoke(ModelServiceContract.start, .object([
            "modelId": .string(selected.id), "messages": input.messages,
            "attachments": .array(input.attachments.enumerated().map { index, attachment in
                .object(["id": .int(index), "name": .string(attachment.name), "mimeType": .string(attachment.mimeType)])
            }),
            "options": .object(["temperature": options.temperature.map(JSONValue.double) ?? .null,
                                "maxTokens": options.maxTokens.map(JSONValue.int) ?? .null]),
        ]))
        guard let fields = value.objectValue, let id = fields["generationId"]?.stringValue, !id.isEmpty, id.count <= 200 else {
            throw WebsiteProviderError("Model service did not return a generation ID; submission may have occurred")
        }
        state = .running(id, Date())
        Log.service.info("ModelService.start domain=\(service.domain) generation=\(id) submission=\(fields["submission"]?.stringValue ?? "uncertain")")
    }

    func read(after cursor: Int) async throws -> WebsiteGenerationUpdate {
        guard case .running(let id, let started) = state else { throw WebsiteProviderError("Model generation is unavailable") }
        guard Date().timeIntervalSince(started) < 300 else { throw WebsiteProviderError("Model generation timed out", kind: .network) }
        let result = try await invoke(ModelServiceContract.read, .object([
            "generationId": .string(id), "after": .int(cursor), "waitMilliseconds": .int(1000),
        ]))
        guard let fields = result.objectValue, case .int(let next) = fields["nextCursor"],
              let values = fields["events"]?.arrayValue, values.count <= 1000 else {
            throw WebsiteProviderError("Model service returned an invalid event batch")
        }
        let events = try values.map { value -> WebsiteGenerationEvent in
            guard let event = value.objectValue else { throw WebsiteProviderError("Invalid model event") }
            switch event["type"]?.stringValue {
            case "text":
                guard let text = event["text"]?.stringValue, text.utf8.count <= 2_000_000 else { throw WebsiteProviderError("Model response is too large") }
                return .textSnapshot(text)
            case "completed": return .completed
            case "failed": return .failed(event["message"]?.stringValue ?? "Model generation failed", LLMFailureKind(rawValue: event["kind"]?.stringValue ?? "") ?? .provider)
            default: throw WebsiteProviderError("Unknown model event")
            }
        }
        return WebsiteGenerationUpdate(nextCursor: next, events: events)
    }

    private func checkPage() throws {
        guard service.owns(page), page.isReady, page.navigationGeneration == navigationGeneration else {
            throw WebsiteProviderError("Model service page was interrupted; the request was not resubmitted", kind: .network)
        }
    }

    private func invoke(_ action: String, _ args: JSONValue) async throws -> JSONValue {
        try Task.checkCancellation()
        try checkPage()
        let value = try await service.invokeAction(action, args: args, role: .modelGeneration, in: page).get()
        try checkPage()
        return value
    }

    func cancelAndClose() async {
        if case .running(let id, _) = state {
            let status = await Task { @MainActor in
                await withTaskGroup(of: JSONValue?.self) { group in
                    group.addTask { @MainActor in
                        try? await self.invoke(ModelServiceContract.cancel, .object(["generationId": .string(id)]))
                    }
                    group.addTask {
                        try? await Task.sleep(for: .seconds(3))
                        return nil
                    }
                    let result = await group.next() ?? nil
                    group.cancelAll()
                    return result
                }
            }.value
            Log.service.info("ModelService.cancel domain=\(service.domain) generation=\(id) status=\(status?.objectValue?["status"]?.stringValue ?? "unconfirmed")")
        }
        close()
    }

    func close() {
        guard case .closed = state else {
            state = .closed
            service.closeOwnedPage(page)
            Self.activeDomains.remove(service.domain)
            Log.service.info("ModelService.close domain=\(service.domain) page=\(page.logLabel)")
            return
        }
    }
}
