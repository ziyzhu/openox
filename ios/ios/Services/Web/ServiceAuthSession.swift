import Foundation
import WebKit

@MainActor
final class ServiceAuthSession: ServiceSheetSession {
    enum Outcome: String, Equatable {
        case signedIn
        case signedOut
        case cancelled
        case failed
        case invalidated
    }

    let id: UUID
    let serviceDomain: String
    let navigationTitle = String(localized: "Sign in")
    var page: WebPage { handoff.page }

    private weak var service: Service?
    private let handoff: ServiceHandoffSession
    private let flowSession: ServiceFlowSession

    init(service: Service, url: URL, flowSession: ServiceFlowSession) {
        let domain = service.domain
        self.flowSession = flowSession
        handoff = flowSession.makeHandoff(
            title: service.title,
            navigationTitle: String(localized: "Sign in"),
            initialURL: url,
            completionProbe: { [weak service, weak flowSession] _ in
                guard let service, let flowSession else { return false }
                let result = await service.getSignInState(in: flowSession).outcome
                if result == .signedIn {
                    Log.service.info("ServiceAuthSession candidate domain=\(service.domain) outcome=signedIn")
                    return true
                }
                return false
            },
            navigationObserver: { event, pageURL in
                guard event == .finished, let pageURL else { return }
                Log.webView.info("Service.navigation event=finish domain=\(domain) scope=auth url=\(LogPrivacy.url(pageURL.absoluteString))")
            }
        )
        id = handoff.id
        serviceDomain = domain
        self.service = service
    }

    func preflight(for duration: Duration) async -> Outcome? {
        guard let outcome = await handoff.preflight(for: duration) else { return nil }
        return map(outcome)
    }

    func attemptSilently(for duration: Duration) async -> Outcome {
        let outcome: Outcome
        if let completed = await handoff.preflight(for: duration) {
            outcome = map(completed)
        } else {
            handoff.cancel()
            outcome = .cancelled
        }
        return await resolve(outcome)
    }

    func present(using presenter: any ServiceAuthPresenting) async -> Outcome {
        let outcome = await presenter.present(session: self)
        guard outcome != .cancelled else { return .cancelled }
        return await resolve(outcome)
    }

    func run() async -> Outcome {
        map(await handoff.run())
    }

    func cancel() {
        handoff.cancel()
    }

    func presentationFailed() {
        handoff.presentationFailed()
    }

    func goBack() {
        handoff.goBack()
    }

    func goForward() {
        handoff.goForward()
    }

    func reload() {
        handoff.reload()
    }

    private func map(_ outcome: ServiceHandoffSession.Outcome) -> Outcome {
        switch outcome {
        case .completed: .signedIn
        case .cancelled: .cancelled
        case .failed: .failed
        }
    }

    private func resolve(_ outcome: Outcome) async -> Outcome {
        guard let service else {
            Log.service.info("ServiceAuthSession verification domain=\(serviceDomain) attempt=\(id.uuidString.prefix(8)) outcome=invalidated")
            return .invalidated
        }
        let result = await service.getSignInState(in: flowSession).outcome
        if result == .signedIn {
            Log.service.info("ServiceAuthSession verification domain=\(service.domain) attempt=\(id.uuidString.prefix(8)) outcome=signedIn")
            return .signedIn
        }
        Log.service.info("ServiceAuthSession verification domain=\(service.domain) attempt=\(id.uuidString.prefix(8)) outcome=\(result.logLabel)")
        if outcome == .signedIn {
            return result == .signedOut ? .signedOut : .failed
        }
        return outcome
    }

}
