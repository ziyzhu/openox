import Foundation
import Network
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
        case verifying
        case completed
        case cancelled
        case failed
    }

    private final class Router {
        var openPopup: @MainActor (URLRequest) -> Void = { _ in }
        var recordDecision: @MainActor (String, Bool) -> Void = { _, _ in }
    }

    private struct NavigationDecider: WebPage.NavigationDeciding {
        let router: Router

        mutating func decidePolicy(
            for action: WebPage.NavigationAction,
            preferences: inout WebPage.NavigationPreferences
        ) async -> WKNavigationActionPolicy {
            guard action.target?.isMainFrame != false else { return .allow }
            guard let url = action.request.url else { return .cancel }
            let allowed = ServiceHandoffSession.allowsNavigation(to: url)
            router.recordDecision(url.host?.lowercased() ?? "?", allowed)
            guard allowed else { return .cancel }
            if action.target == nil {
                router.openPopup(action.request)
                return .cancel
            }
            return .allow
        }
    }

    let id = UUID()
    let serviceDomain: String
    let title: String
    let navigationTitle: String
    let page: WebPage
    private(set) var phase: Phase = .ready

    private let initialURL: URL
    private let completionProbe: @MainActor (URL?) async -> Bool
    private let navigationObserver: @MainActor (WebPage.NavigationEvent, URL?) -> Void
    private var completion: CheckedContinuation<Outcome, Never>?
    private var navigationTask: Task<Void, Never>?
    private var periodicProbeTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?

    init(
        serviceDomain: String,
        title: String,
        navigationTitle: String,
        initialURL: URL,
        configuration: WebPage.Configuration,
        completionProbe: @escaping @MainActor (URL?) async -> Bool,
        navigationObserver: @escaping @MainActor (WebPage.NavigationEvent, URL?) -> Void = { _, _ in }
    ) {
        let router = Router()
        self.serviceDomain = serviceDomain
        self.title = title
        self.navigationTitle = navigationTitle
        self.initialURL = initialURL
        self.completionProbe = completionProbe
        self.navigationObserver = navigationObserver
        self.page = WebPage(configuration: configuration, navigationDecider: NavigationDecider(router: router))
        router.openPopup = { [weak self] request in self?.loadPopup(request) }
        router.recordDecision = { [weak self] host, allowed in self?.recordDecision(host: host, allowed: allowed) }
        #if targetEnvironment(simulator)
        page.isInspectable = true
        #endif
    }

    func run() async -> Outcome {
        if let outcome = terminalOutcome { return outcome }
        if phase == .ready { start() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func preflight(for duration: Duration) async -> Outcome? {
        if let outcome = terminalOutcome { return outcome }
        if phase == .ready { start() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        while clock.now < deadline {
            if let outcome = terminalOutcome { return outcome }
            if Task.isCancelled {
                cancel()
                return .cancelled
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return terminalOutcome
    }

    func cancel() {
        finish(.cancelled)
    }

    func presentationFailed() {
        finish(.failed)
    }

    func goBack() {
        guard let item = page.backForwardList.backList.last else { return }
        page.load(item)
    }

    func goForward() {
        guard let item = page.backForwardList.forwardList.first else { return }
        page.load(item)
    }

    func reload() {
        page.reload()
    }

    private func start() {
        phase = .running
        let attempt = id.uuidString.prefix(8)
        Log.service.info("ServiceHandoffSession state domain=\(serviceDomain) attempt=\(attempt) phase=running")
        navigationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await observeNavigations()
        }
        periodicProbeTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                requestProbe(reason: "periodic")
            }
        }
        page.load(initialURL)
    }

    private func observeNavigations() async {
        while !Task.isCancelled, phase == .running || phase == .verifying {
            do {
                for try await event in page.navigations {
                    guard !Task.isCancelled else { return }
                    receive(event)
                }
                return
            } catch is CancellationError {
                return
            } catch {
                let currentURL = LogPrivacy.url(page.url?.absoluteString ?? "?")
                let details = LogPrivacy.text(Self.failureDetails(error), limit: 1_024)
                Log.service.warning("ServiceHandoffSession navigation error domain=\(serviceDomain) attempt=\(id.uuidString.prefix(8)) current=\(currentURL) disposition=continue \(details)")
            }
        }
    }

    private func receive(_ event: WebPage.NavigationEvent) {
        let attempt = id.uuidString.prefix(8)
        let host = page.url?.host?.lowercased() ?? "?"
        Log.service.info("ServiceHandoffSession navigation domain=\(serviceDomain) attempt=\(attempt) event=\(String(describing: event)) host=\(host)")
        navigationObserver(event, page.url)
        if event == .finished, isServiceHost(host) {
            requestProbe(reason: "service-return")
        }
    }

    private func loadPopup(_ request: URLRequest) {
        guard phase == .running || phase == .verifying else { return }
        let host = request.url?.host?.lowercased() ?? "?"
        Log.service.info("ServiceHandoffSession popup domain=\(serviceDomain) attempt=\(id.uuidString.prefix(8)) host=\(host) disposition=same-page")
        page.load(request)
    }

    private func recordDecision(host: String, allowed: Bool) {
        Log.service.info("ServiceHandoffSession policy domain=\(serviceDomain) attempt=\(id.uuidString.prefix(8)) host=\(host) allowed=\(allowed)")
    }

    private func requestProbe(reason: String) {
        guard phase == .running || phase == .verifying, probeTask == nil else { return }
        phase = .verifying
        let attempt = id.uuidString.prefix(8)
        Log.service.info("ServiceHandoffSession probe domain=\(serviceDomain) attempt=\(attempt) reason=\(reason) phase=start")
        probeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let completed = await completionProbe(page.url)
            guard !Task.isCancelled, phase == .verifying else { return }
            probeTask = nil
            Log.service.info("ServiceHandoffSession probe domain=\(serviceDomain) attempt=\(attempt) reason=\(reason) outcome=\(completed ? "completed" : "pending")")
            if completed {
                finish(.completed)
            } else {
                phase = .running
            }
        }
    }

    private static func failureDetails(_ error: any Error) -> String {
        guard let navigationError = error as? WebPage.NavigationError else {
            return errorDetails(kind: "other", error: error)
        }
        switch navigationError {
        case .failedProvisionalNavigation(let cause):
            return errorDetails(kind: "failedProvisionalNavigation", error: cause)
        case .pageClosed:
            return "kind=pageClosed"
        case .webContentProcessTerminated:
            return "kind=webContentProcessTerminated"
        case .invalidURL:
            return "kind=invalidURL"
        @unknown default:
            return errorDetails(kind: "unknownNavigationError", error: navigationError)
        }
    }

    private static func errorDetails(kind: String, error: any Error) -> String {
        let failure = error as NSError
        var values = [
            "kind=\(kind)",
            "domain=\(failure.domain)",
            "code=\(failure.code)",
            "description=\(failure.localizedDescription)"
        ]
        if let reason = failure.localizedFailureReason {
            values.append("reason=\(reason)")
        }
        if let failingURL = (failure.userInfo[NSURLErrorFailingURLErrorKey] as? NSURL)?.absoluteString {
            values.append("url=\(LogPrivacy.url(failingURL))")
        }
        if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError {
            values.append("underlyingDomain=\(underlying.domain)")
            values.append("underlyingCode=\(underlying.code)")
            values.append("underlyingDescription=\(underlying.localizedDescription)")
        }
        return values.joined(separator: " ")
    }

    private func finish(_ outcome: Outcome) {
        guard phase != .completed, phase != .cancelled, phase != .failed else { return }
        switch outcome {
        case .completed: phase = .completed
        case .cancelled: phase = .cancelled
        case .failed: phase = .failed
        }
        navigationTask?.cancel()
        navigationTask = nil
        periodicProbeTask?.cancel()
        periodicProbeTask = nil
        probeTask?.cancel()
        probeTask = nil
        page.stopLoading()
        Log.service.info("ServiceHandoffSession state domain=\(serviceDomain) attempt=\(id.uuidString.prefix(8)) phase=\(outcome.rawValue)")
        let completion = completion
        self.completion = nil
        completion?.resume(returning: outcome)
    }

    private var terminalOutcome: Outcome? {
        switch phase {
        case .completed: .completed
        case .cancelled: .cancelled
        case .failed: .failed
        case .ready, .running, .verifying: nil
        }
    }

    private func isServiceHost(_ host: String) -> Bool {
        host == serviceDomain || host.hasSuffix("." + serviceDomain)
    }

    static func allowsNavigation(to url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "about" { return true }
        guard let host = url.host?.lowercased() else { return false }
        #if targetEnvironment(simulator)
        if scheme == "http", isLoopback(host) { return true }
        #endif
        return scheme == "https" && !isPrivateNetwork(host)
    }

    private static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" { return true }
        guard let address = IPv4Address(host) else { return false }
        return address.rawValue.first == 127
    }

    private static func isPrivateNetwork(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if let address = IPv4Address(host) {
            let bytes = Array(address.rawValue)
            guard bytes.count == 4 else { return true }
            return bytes[0] == 10
                || bytes[0] == 127
                || bytes[0] == 0
                || bytes[0] == 169 && bytes[1] == 254
                || bytes[0] == 172 && (16...31).contains(bytes[1])
                || bytes[0] == 192 && bytes[1] == 168
        }
        if let address = IPv6Address(host) {
            let bytes = Array(address.rawValue)
            guard bytes.count == 16 else { return true }
            return bytes.dropFirst().allSatisfy { $0 == 0 } && bytes[0] == 0 && bytes[15] == 1
                || bytes[0] & 0xfe == 0xfc
                || bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
        }
        return false
    }
}
