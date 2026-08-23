import Foundation

extension Service {
    func completeBotControl(args: JSONValue, using presenter: any ServiceHandoffPresenting) async -> Bool {
        let outcome = await manager.sessionCoordinator.run(for: self, kind: .botControl) { [weak self] flowID in
            guard let self else { return .cancelled }
            let completed = await self.performBotControl(args: args, using: presenter, flowID: flowID)
            return .botControl(completed)
        }
        if case .botControl(let completed) = outcome {
            return completed
        }
        return false
    }

    private func performBotControl(
        args: JSONValue,
        using presenter: any ServiceHandoffPresenting,
        flowID: UUID
    ) async -> Bool {
        guard definition.action(Manifest.BOT_CONTROL_URL_ACTION_ID, includingStandard: true) != nil,
              definition.action(Manifest.BOT_CONTROL_STATE_ACTION_ID, includingStandard: true) != nil,
              let episodeArgs = args.objectValue else {
            Log.service.error("Service.completeBotControl unavailable domain=\(domain)")
            return false
        }
        guard let flowSession = try? await ServiceFlowSession.open(
            id: flowID,
            kind: .botControl,
            service: self,
            actionID: Manifest.BOT_CONTROL_URL_ACTION_ID,
            args: args,
            role: .blockingAction
        ) else {
            Log.service.error("Service.completeBotControl action page unavailable domain=\(domain)")
            return false
        }
        defer { flowSession.close() }
        let urlResult = await flowSession.invoke(
            Manifest.BOT_CONTROL_URL_ACTION_ID,
            args: args,
            role: .blockingAction
        )
        guard case .success(let value) = urlResult,
              let rawURL = Manifest.authURL(value),
              let url = URL(string: rawURL),
              ServiceHandoffSession.allowsNavigation(to: url) else {
            Log.service.error("Service.completeBotControl invalid URL domain=\(domain)")
            return false
        }
        let session = ServiceBotControlSession(
            service: self,
            url: url,
            args: episodeArgs,
            flowSession: flowSession
        )
        Log.service.info("Service.completeBotControl presenting domain=\(domain) attempt=\(session.handoff.id.uuidString.prefix(8))")
        let outcome = await session.present(using: presenter)
        Log.service.info("Service.completeBotControl done domain=\(domain) outcome=\(outcome.rawValue)")
        return outcome == .completed
    }
}

@MainActor
final class ServiceBotControlSession {
    enum Outcome: String, Equatable {
        case completed
        case cancelled
        case failed
        case invalidated
    }

    let handoff: ServiceHandoffSession

    private weak var service: Service?
    private let flowSession: ServiceFlowSession

    init(
        service: Service,
        url: URL,
        args: [String: JSONValue],
        flowSession: ServiceFlowSession
    ) {
        self.service = service
        self.flowSession = flowSession
        handoff = flowSession.makeHandoff(
            title: service.title,
            navigationTitle: String(localized: "Verify"),
            initialURL: url,
            completionProbe: { [weak service, weak flowSession] pageURL in
                guard service != nil, let flowSession, let pageURL else { return false }
                var probeArgs = args
                probeArgs["pageUrl"] = .string(pageURL.absoluteString)
                let result = await flowSession.invoke(
                    Manifest.BOT_CONTROL_STATE_ACTION_ID,
                    args: .object(probeArgs),
                    role: .blockingAction
                )
                guard case .success(let value) = result else { return false }
                return value.objectValue?["ok"]?.boolValue == true
            }
        )
    }

    func present(using presenter: any ServiceHandoffPresenting) async -> Outcome {
        let outcome = await presenter.present(session: handoff)
        guard service != nil else { return .invalidated }
        switch outcome {
        case .completed:
            return .completed
        case .cancelled:
            return .cancelled
        case .failed:
            return .failed
        }
    }
}
