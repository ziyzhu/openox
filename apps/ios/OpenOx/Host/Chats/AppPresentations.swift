import Foundation
import Observation

enum MessageDisposition: String {
    case sent
    case cancelled
    case failed
}

enum MessageComposeError: LocalizedError {
    case unavailable
    case noPresenter

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "This device can't send text messages — the iOS Simulator has no Messages app. The compose sheet only works on a real iPhone. Tell the user."
        case .noPresenter:
            return "Couldn't open the message composer — no active window to present from."
        }
    }
}

@MainActor
protocol ServiceHandoffPresenting {
    func present(session: ServiceHandoffSession) async -> ServiceHandoffSession.Outcome
}

@MainActor
protocol ServiceAuthPresenting {
    func present(session: ServiceAuthSession) async -> ServiceAuthSession.Outcome
}

@MainActor
protocol MessageComposing {
    var canSend: Bool { get }
    func present(recipients: [String], body: String?) async throws -> MessageDisposition
}

@MainActor
struct AppPresentations {
    let serviceSignIn: any ServiceAuthPresenting
    let serviceHandoff: any ServiceHandoffPresenting
    let messages: any MessageComposing

    static let unavailable = AppPresentations(
        serviceSignIn: UnavailableServiceAuthPresenter(),
        serviceHandoff: UnavailableServiceHandoffPresenter(),
        messages: UnavailableMessageComposer()
    )
}

@MainActor
@Observable
final class AppPresentationCoordinator {
    enum Content {
        case browser(ServiceBrowserSession)
        case serviceSignIn(ServiceAuthSession)
        case serviceHandoff(ServiceHandoffSession)
    }

    struct Presented: Identifiable {
        let id = UUID()
        let content: Content
    }

    static let shared = AppPresentationCoordinator()

    private(set) var presented: Presented?
    private var hostActive = false

    func setHostActive(_ active: Bool) {
        hostActive = active
    }

    func detachHost() {
        hostActive = false
        dismissPresented()
    }

    @discardableResult
    func presentBrowser(_ session: ServiceBrowserSession) -> Bool {
        present(.browser(session), label: "browser") != nil
    }

    func presentServiceAuth(_ session: ServiceAuthSession) async -> ServiceAuthSession.Outcome {
        if let outcome = await session.preflight(for: .seconds(1)) {
            Log.ui.info("ServiceAuthSheet preflight domain=\(session.serviceDomain) outcome=\(outcome.rawValue)")
            return outcome
        }
        guard let id = present(.serviceSignIn(session), label: "service-auth") else {
            session.presentationFailed()
            return .failed
        }
        Log.ui.info("ServiceAuthSheet present domain=\(session.serviceDomain)")
        let outcome = await session.run()
        dismiss(id: id)
        return outcome
    }

    func presentServiceHandoff(_ session: ServiceHandoffSession) async -> ServiceHandoffSession.Outcome {
        if let outcome = await session.preflight(for: .seconds(1)) {
            Log.ui.info("ServiceHandoffSheet preflight domain=\(session.serviceDomain) outcome=\(outcome.rawValue)")
            return outcome
        }
        guard let id = present(.serviceHandoff(session), label: "service-handoff") else {
            session.presentationFailed()
            return .failed
        }
        Log.ui.info("ServiceHandoffSheet present domain=\(session.serviceDomain)")
        let outcome = await session.run()
        dismiss(id: id)
        return outcome
    }

    func dismissPresented() {
        guard let presented else { return }
        switch presented.content {
        case .browser(let session): session.stop()
        case .serviceSignIn(let session): session.cancel()
        case .serviceHandoff(let session): session.cancel()
        }
        self.presented = nil
    }

    private func present(_ content: Content, label: String) -> UUID? {
        guard hostActive, presented == nil else {
            Log.ui.warning("AppPresentation.rejected kind=\(label) hostActive=\(hostActive) occupied=\(presented != nil)")
            return nil
        }
        let presented = Presented(content: content)
        self.presented = presented
        return presented.id
    }

    private func dismiss(id: UUID) {
        guard presented?.id == id else { return }
        presented = nil
    }
}

extension AppPresentationCoordinator: ServiceAuthPresenting {
    func present(session: ServiceAuthSession) async -> ServiceAuthSession.Outcome {
        await presentServiceAuth(session)
    }
}

@MainActor
private struct UnavailableServiceAuthPresenter: ServiceAuthPresenting {
    func present(session: ServiceAuthSession) async -> ServiceAuthSession.Outcome {
        session.presentationFailed()
        return .failed
    }
}

@MainActor
private struct UnavailableServiceHandoffPresenter: ServiceHandoffPresenting {
    func present(session: ServiceHandoffSession) async -> ServiceHandoffSession.Outcome {
        session.presentationFailed()
        return .failed
    }
}

@MainActor
private struct UnavailableMessageComposer: MessageComposing {
    var canSend: Bool { false }

    func present(recipients: [String], body: String?) async throws -> MessageDisposition {
        throw MessageComposeError.unavailable
    }
}

extension AppPresentations {
    static let live = AppPresentations(
        serviceSignIn: AppPresentationCoordinator.shared,
        serviceHandoff: ServiceHandoffSheetPresenter(coordinator: .shared),
        messages: MessageSheetComposer()
    )
}

@MainActor
private struct ServiceHandoffSheetPresenter: ServiceHandoffPresenting {
    let coordinator: AppPresentationCoordinator

    func present(session: ServiceHandoffSession) async -> ServiceHandoffSession.Outcome {
        await coordinator.presentServiceHandoff(session)
    }
}

@MainActor
private struct MessageSheetComposer: MessageComposing {
    var canSend: Bool { MessageComposer.canSend }

    func present(recipients: [String], body: String?) async throws -> MessageDisposition {
        try await MessageComposer.present(recipients: recipients, body: body)
    }
}
