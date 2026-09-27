import Foundation

@MainActor
final class ModelServiceSession {
    private enum State {
        case ready
        case starting
        case running(String, Date)
        case closed
    }

    private let service: Service
    private let page: Service.ServiceWebPage
    private let navigationGeneration: Int
    private var state = State.ready
    private var stream = ModelServiceStreamState()

    private init(service: Service, page: Service.ServiceWebPage) {
        self.service = service
        self.page = page
        navigationGeneration = page.navigationGeneration
    }

    static func open(service: Service) async throws -> ModelServiceSession {
        guard let action = await service.resolvedAction(ModelServiceContract.start, role: .modelGeneration) else {
            throw WebsiteProviderError("Model service source is unavailable")
        }
        let page = try await service.openOwnedPage(for: action, owner: .model(UUID()))
        if Task.isCancelled {
            service.closeOwnedPage(page)
            throw CancellationError()
        }
        Log.service.info("ModelService.open domain=\(service.domain) source=\(service.definition.repositoryID ?? "unknown") page=\(page.logLabel)")
        return ModelServiceSession(service: service, page: page)
    }

    func start(model: ProviderModel, input: WebsiteProviderInput, options: StreamOptions) async throws {
        guard case .ready = state else { throw WebsiteProviderError("Model generation has already started") }
        try await WebsiteAttachmentTransfer.stage(input.attachments, on: page.page)
        state = .starting
        let value = try await invoke(ModelServiceContract.start, .object([
            "modelId": .string(model.wireID), "messages": input.messages,
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

    func next() async throws -> ModelServiceStreamState {
        guard case .running(let id, let started) = state else { throw WebsiteProviderError("Model generation is unavailable") }
        guard Date().timeIntervalSince(started) < 300 else { throw WebsiteProviderError("Model generation timed out", kind: .network) }
        let cursor = stream.cursor
        try stream.accept(try await invoke(ModelServiceContract.read, .object([
            "generationId": .string(id), "after": .int(cursor), "waitMilliseconds": .int(1000),
        ])))
        if stream.cursor == cursor { try await Task.sleep(for: .milliseconds(100)) }
        return stream
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
            Log.service.info("ModelService.close domain=\(service.domain) page=\(page.logLabel)")
            return
        }
    }
}
