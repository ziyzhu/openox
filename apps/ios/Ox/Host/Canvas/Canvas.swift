import Foundation
import Observation

@MainActor
@Observable
final class OxCanvas {
    enum State {
        case running, closed
    }

    enum Interaction: Identifiable {
        case approval(ServiceApproval.Request)
        case choice(UUID, String, [String])
        case control(UUID, ServiceControl, Service)

        var id: UUID {
            switch self {
            case .approval(let request): request.id
            case .choice(let id, _, _), .control(let id, _, _): id
            }
        }
    }

    struct Browser: Identifiable {
        let id: UUID
        let service: Service
    }

    let id = UUID()
    let title: String
    let serviceManager: ServiceManager
    let presentations: AppPresentationCoordinator
    private var state: State = .running
    private var outputs: [Artifact] = []
    private(set) var interaction: Interaction?
    var browser: Browser?

    @ObservationIgnored private var services: [String: Service] = [:]
    @ObservationIgnored private var loading: [String: Task<Service, Error>] = [:]
    private var pending: [UUID: Task<JSONValue?, Error>] = [:]
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var answer: CheckedContinuation<JSONValue?, Never>?
    @ObservationIgnored private var requestTimes: [Date] = []
    @ObservationIgnored private var activeAuth: ServiceAuthSession?
    @ObservationIgnored private var activeHandoff: ServiceHandoffSession?
    @ObservationIgnored private var messagePresentationID: UUID?
    @ObservationIgnored private var outputBytes = 0
    @ObservationIgnored private var repositoryRevision: UInt64

    init(title: String, serviceManager: ServiceManager, presentations: AppPresentationCoordinator) {
        self.title = title
        self.serviceManager = serviceManager
        self.presentations = presentations
        repositoryRevision = serviceManager.monoRepositoryRevision
    }

    var outputDirectory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("ox-canvas-\(id.uuidString)", isDirectory: true) }

    func call(function: String, arguments: JSONValue) async throws -> JSONValue? {
        try requireRunning()
        try CanvasServiceCatalog.validate(function: function, arguments: arguments)
        guard arguments.jsonString().utf8.count <= 1_048_576 else { throw RuntimeError.bridge("Canvas request exceeds 1 MiB") }
        let now = Date()
        requestTimes.removeAll { now.timeIntervalSince($0) > 60 }
        guard pending.count < 16, requestTimes.count < 120 else {
            throw RuntimeError.bridge("Canvas service call limit reached; wait before retrying")
        }
        requestTimes.append(now)
        let requestID = UUID()
        let previous = tail
        let task = Task { @MainActor [self] in
            await previous?.value
            try requireRunning()
            let timeout = Task { @MainActor [weak self] in
                var activeSeconds = 0
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self else { return }
                    if interaction == nil, messagePresentationID == nil { activeSeconds += 1 }
                    if activeSeconds >= 60 {
                        pending[requestID]?.cancel()
                        Log.service.error("Canvas.timeout caller=\(id) function=\(function)")
                        return
                    }
                }
            }
            defer { timeout.cancel() }
            let result = try await operations.call(function: function, arguments: arguments)
            try requireRunning()
            guard (result?.jsonString().utf8.count ?? 0) <= 8 * 1_048_576 else {
                throw RuntimeError.bridge("Canvas response exceeds 8 MiB")
            }
            return result
        }
        pending[requestID] = task
        tail = Task { _ = await task.result }
        defer {
            pending.removeValue(forKey: requestID)
            if pending.isEmpty { tail = nil }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    func close() {
        guard state != .closed else { return }
        state = .closed
        cancelWork()
        try? FileManager.default.removeItem(at: outputDirectory)
        outputs = []
        Log.service.info("Canvas.close caller=\(id)")
    }

    private func cancelWork() {
        pending.values.forEach { $0.cancel() }
        loading.values.forEach { $0.cancel() }
        resolveInteraction(id: interaction?.id, value: nil)
        browser = nil
        activeAuth?.cancel()
        activeHandoff?.cancel()
        serviceManager.browserActionSessions.closeSession(for: id)
        for service in services.values where service.isWebService { service.discardPages() }
    }

    private func requireRunning() throws {
        try Task.checkCancellation()
        guard state == .running else { throw RuntimeError.bridge("Canvas has closed") }
    }

    private func resolveService(_ domain: String) async throws -> Service {
        try requireRunning()
        if repositoryRevision != serviceManager.monoRepositoryRevision {
            for service in services.values where service.isWebService { service.discardPages() }
            services = [:]
            repositoryRevision = serviceManager.monoRepositoryRevision
        }
        if let service = services[domain] { return service }
        if let task = loading[domain] { return try await task.value }
        let task = Task { @MainActor in try await serviceManager.serviceForCaller(domain: domain, reason: .invoke) }
        loading[domain] = task
        defer { loading.removeValue(forKey: domain) }
        let service = try await task.value
        try requireRunning()
        services[domain] = service
        Log.service.info("Canvas.service resolved caller=\(id) domain=\(domain)")
        return service
    }

    private func resolveAction(_ name: String) async throws -> (Service, String) {
        let parts = name.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, ["web", "ios", "mcp"].contains(parts[0]), !parts[1].isEmpty, !parts[2].isEmpty else {
            throw RuntimeError.bridge("Use a qualified action: web:<domain>:<action>, ios:<app>:<action>, or mcp:<server>:<action>")
        }
        let service = try await resolveService(parts[0] == "ios" ? "ios:\(parts[1])" : parts[1])
        let kind = service.isIOSService ? "ios" : service.isMCPService ? "mcp" : "web"
        guard kind == parts[0] else { throw Service.InvokeError.unknown(name) }
        return (service, parts[2])
    }

    private var operations: ServiceOperations {
        ServiceOperations(
            serviceManager: serviceManager,
            resolveService: { [unowned self] in try await resolveService($0) },
            resolveAction: { [unowned self] in try await resolveAction($0) },
            approve: { [unowned self] action, args, prompt in
                let outcome = await ServiceApproval(serviceManager: serviceManager, ownerID: id, callerName: title, resolveService: { self.services[$0] })
                    .request(action: action, args: args, prompt: prompt) { request in
                        await self.waitForInteraction(.approval(request))?.stringValue
                    }
                guard outcome.isApproved else { throw RuntimeError.bridge("\(action): the user declined or stopped") }
            },
            presentControl: { [unowned self] control, service in
                await waitForInteraction(.control(UUID(), control, service))
            },
            receiveArtifacts: { [unowned self] in try receiveArtifacts($0) },
            serviceChanged: { [unowned self] domain in
                if let service = services.removeValue(forKey: domain), service.isWebService { service.discardPages() }
            },
            begin: { [unowned self] function, _, purpose in
                let invocation = UUID()
                Log.service.info("Canvas.invoke caller=\(id) request=\(invocation) function=\(function) purpose=\(purpose)")
                return invocation
            },
            finish: { [unowned self] invocation, result in
                let outcome = switch result {
                case .success: "succeeded"
                case .failure(let error): "failed error=\(error.localizedDescription)"
                }
                Log.service.info("Canvas.result caller=\(id) request=\(invocation) outcome=\(outcome)")
            },
            native: NativeServiceOperations(
                id: id,
                serviceManager: serviceManager,
                presentations: AppPresentations(
                    serviceSignIn: CanvasAuthPresenter(canvas: self),
                    serviceHandoff: CanvasHandoffPresenter(canvas: self),
                    messages: CanvasMessagePresenter(canvas: self)
                ),
                requireActive: { [unowned self] in try requireRunning() },
                showBrowser: { [unowned self] service, owner in browser = Browser(id: owner, service: service) },
                attachTransient: { _ in
                    throw RuntimeError.bridge("Browser screenshots are available only to chat agents.")
                },
                choose: { [unowned self] prompt in
                    await waitForInteraction(.choice(UUID(), prompt.body, prompt.options))?.stringValue
                }
            )
        )
    }

    private func waitForInteraction(_ value: Interaction) async -> JSONValue? {
        guard state == .running, !Task.isCancelled, interaction == nil else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                interaction = value
                answer = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolveInteraction(id: value.id, value: nil) }
        }
    }

    func resolveInteraction(id requestID: UUID?, value: JSONValue?) {
        guard let requestID, interaction?.id == requestID else { return }
        let continuation = answer
        answer = nil
        interaction = nil
        continuation?.resume(returning: value)
    }

    func performControl(_ control: ServiceControl, service: Service) async -> JSONValue? {
        guard state == .running else { return nil }
        switch control {
        case .signIn:
            await service.signIn(using: CanvasAuthPresenter(canvas: self), source: .canvas)
            return service.signInState.isAuthenticated ? .null : nil
        case .botControl(_, _, let args):
            return await service.completeBotControl(args: args, using: CanvasHandoffPresenter(canvas: self)) ? .null : nil
        case .payment(_, _, let args):
            return await service.completePayment(args: args, using: CanvasHandoffPresenter(canvas: self))
        }
    }

    fileprivate func presentAuth(_ auth: ServiceAuthSession) async -> ServiceAuthSession.Outcome {
        guard state == .running else { auth.cancel(); return .cancelled }
        activeAuth = auth
        defer { if activeAuth === auth { activeAuth = nil } }
        return await presentations.presentServiceAuth(auth)
    }

    fileprivate func presentHandoff(_ handoff: ServiceHandoffSession) async -> ServiceHandoffSession.Outcome {
        guard state == .running else { handoff.cancel(); return .cancelled }
        activeHandoff = handoff
        defer { if activeHandoff === handoff { activeHandoff = nil } }
        return await presentations.presentServiceHandoff(handoff)
    }

    fileprivate func presentMessages(recipients: [String], body: String?) async throws -> MessageDisposition {
        try requireRunning()
        let presentationID = UUID()
        messagePresentationID = presentationID
        defer { if messagePresentationID == presentationID { messagePresentationID = nil } }
        return try await AppPresentations.live.messages.present(recipients: recipients, body: body)
    }

    private func receiveArtifacts(_ artifacts: [RemoteMCPArtifact]) throws {
        try requireRunning()
        let added = artifacts.reduce(0) { $0 + $1.data.count }
        guard outputBytes + added <= 20 * 1_048_576, outputs.count + artifacts.count <= 32 else {
            throw RuntimeError.bridge("Canvas output limit reached")
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for artifact in artifacts {
            let name = (try? ArtifactStore.validatedFilename(artifact.suggestedFilename)) ?? "output.dat"
            let filename = "\(UUID().uuidString.prefix(8))-\(name)"
            let file = outputDirectory.appendingPathComponent(filename)
            try artifact.data.write(to: file, options: .atomic)
            outputBytes += artifact.data.count
            outputs.append(Artifact(fileName: filename, directory: outputDirectory))
        }
    }
}

@MainActor
private struct CanvasAuthPresenter: ServiceAuthPresenting {
    let canvas: OxCanvas
    func present(session: ServiceAuthSession) async -> ServiceAuthSession.Outcome {
        await canvas.presentAuth(session)
    }
}

@MainActor
private struct CanvasHandoffPresenter: ServiceHandoffPresenting {
    let canvas: OxCanvas
    func present(session: ServiceHandoffSession) async -> ServiceHandoffSession.Outcome {
        await canvas.presentHandoff(session)
    }
}

@MainActor
private struct CanvasMessagePresenter: MessageComposing {
    let canvas: OxCanvas
    var canSend: Bool { AppPresentations.live.messages.canSend }
    func present(recipients: [String], body: String?) async throws -> MessageDisposition {
        try await canvas.presentMessages(recipients: recipients, body: body)
    }
}
