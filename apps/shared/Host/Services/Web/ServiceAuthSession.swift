import Foundation
import WebKit

@MainActor
final class ServiceAuthSession {
    enum Outcome: String, Equatable {
        case signedIn
        case acknowledged
        case signedOut
        case cancelled
        case failed
        case invalidated
    }

    let id: UUID
    let serviceDomain: String
    let navigationTitle = String(localized: "Sign in")
    var page: WebPage { handoff.page }

    private enum CompletionSource {
        case detector
        case user
    }

    private final class ProbeObservation {
        var result: GetSignInStateResult?
    }

    private let probeObservation: ProbeObservation
    private var completionSource: CompletionSource = .detector
    private weak var service: Service?
    private let handoff: ServiceHandoffSession
    private let flowSession: ServiceFlowSession

    init(service: Service, url: URL, flowSession: ServiceFlowSession) {
        let domain = service.domain
        let observation = ProbeObservation()
        probeObservation = observation
        self.flowSession = flowSession
        handoff = flowSession.makeHandoff(
            title: service.title,
            navigationTitle: String(localized: "Sign in"),
            initialURL: url,
            completionProbe: { [weak service, weak flowSession] _ in
                guard let service, let flowSession else { return false }
                let result = await service.getSignInState(in: flowSession)
                guard !Task.isCancelled else { return false }
                observation.result = result
                if result.outcome == .signedIn {
                    Log.service.info("ServiceAuthSession candidate domain=\(service.domain) outcome=signedIn")
                    return true
                }
                return false
            },
            navigationObserver: { event, pageURL in
                guard event == .finished, let pageURL else { return }
                Log.webView.info("Service.navigation event=finish domain=\(domain) scope=auth host=\(pageURL.host ?? "?")")
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

    var observedAccess: Service.Auth {
        guard let result = probeObservation.result else {
            return .unavailable(previous: service?.auth.observation, error: "Sign-in has not been verified")
        }
        switch result.outcome {
        case .signedIn: return .observed(.init(value: .signedIn, observedAt: result.at))
        case .signedOut: return .observed(.init(value: .signedOut, observedAt: result.at))
        case .error(let message): return .unavailable(previous: service?.auth.observation, error: message)
        }
    }

    func acknowledgeSignIn() {
        guard handoff.phase == .running || handoff.phase == .verifying else { return }
        completionSource = .user
        Log.service.info("ServiceAuthSession acknowledgment domain=\(serviceDomain) attempt=\(id.uuidString.prefix(8)) detector=\(probeObservation.result?.outcome.logLabel ?? "unchecked")")
        handoff.complete()
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

    func navigate(to url: URL) -> Bool {
        handoff.navigate(to: url)
    }

    private func map(_ outcome: ServiceHandoffSession.Outcome) -> Outcome {
        switch outcome {
        case .completed: completionSource == .user ? .acknowledged : .signedIn
        case .cancelled: .cancelled
        case .failed: .failed
        }
    }

    private func resolve(_ outcome: Outcome) async -> Outcome {
        guard let service else {
            Log.service.info("ServiceAuthSession verification domain=\(serviceDomain) attempt=\(id.uuidString.prefix(8)) outcome=invalidated")
            return .invalidated
        }
        guard outcome != .acknowledged else { return .acknowledged }
        if outcome == .signedIn, probeObservation.result?.outcome == .signedIn {
            Log.service.info("ServiceAuthSession verification domain=\(serviceDomain) attempt=\(id.uuidString.prefix(8)) outcome=signedIn source=detector")
            return .signedIn
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
