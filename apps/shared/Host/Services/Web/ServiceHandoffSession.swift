import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class ServiceHandoffSession {
    enum Outcome: String {
        case completed
        case cancelled
        case failed
    }

    enum Phase: String {
        case ready
        case running
        case completed
        case cancelled
        case failed
    }

    let id = UUID()
    let serviceDomain: String
    let title: String
    let navigationTitle: String
    let page: WebPage
    let control: ServiceControl?
    private(set) var phase: Phase = .ready

    private weak var service: Service?
    private let servicePage: BrowserSession
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var completion: CheckedContinuation<Outcome, Never>?

    init(
        service: Service,
        servicePage: BrowserSession,
        title: String,
        navigationTitle: String,
        control: ServiceControl? = nil
    ) {
        self.service = service
        self.servicePage = servicePage
        serviceDomain = service.domain
        self.title = title
        self.navigationTitle = navigationTitle
        self.control = control
        page = servicePage.page
    }

    func run() async -> Outcome {
        if let outcome = terminalOutcome { return outcome }
        phase = .running
        startedAt = ProcessInfo.processInfo.systemUptime
        Log.service.info("ServiceHandoffSession state domain=\(serviceDomain) attempt=\(id.uuidString.prefix(8)) phase=running \(diagnosticContext)")
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func dismissPresentation() {
        finish(.completed)
    }

    func cancel() {
        finish(.cancelled)
    }

    func presentationFailed() {
        finish(.failed)
    }

    func goBack() {
        guard let service else { return }
        Task { await service.goBack(servicePage) }
    }

    func goForward() {
        guard let service else { return }
        Task { await service.goForward(servicePage) }
    }

    func reload() {
        guard let service else { return }
        Task { await service.reload(servicePage) }
    }

    func navigate(to url: URL) -> Bool {
        guard phase == .running, let service,
              BrowserNavigation.allowsServiceNavigation(url) else {
            Log.service.warning("ServiceHandoffSession address rejected domain=\(serviceDomain) attempt=\(id.uuidString.prefix(8)) host=\(url.host ?? "?") phase=\(phase.rawValue)")
            return false
        }
        Task { await service.navigate(url, in: servicePage) }
        return true
    }

    private var diagnosticContext: String {
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        return "elapsedMs=\(elapsed) session=\(servicePage.logLabel) nav=\(servicePage.navigationGeneration)/\(servicePage.finishedNavigationGeneration) loading=\(page.isLoading) progress=\(page.estimatedProgress) current=\(LogPrivacy.url(page.url?.absoluteString ?? "?"))"
    }

    private func finish(_ outcome: Outcome) {
        guard terminalOutcome == nil else { return }
        switch outcome {
        case .completed: phase = .completed
        case .cancelled: phase = .cancelled
        case .failed: phase = .failed
        }
        Log.service.info("ServiceHandoffSession state domain=\(serviceDomain) attempt=\(id.uuidString.prefix(8)) phase=\(outcome.rawValue) \(diagnosticContext)")
        let completion = completion
        self.completion = nil
        completion?.resume(returning: outcome)
    }

    private var terminalOutcome: Outcome? {
        switch phase {
        case .completed: .completed
        case .cancelled: .cancelled
        case .failed: .failed
        case .ready, .running: nil
        }
    }
}
