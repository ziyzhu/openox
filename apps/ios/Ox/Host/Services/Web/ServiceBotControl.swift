import Foundation

extension Service {
    func completeBotControl(
        args: JSONValue,
        using presenter: any ServiceHandoffPresenting,
        source: ServiceActionScheduler.BotControlLease? = nil
    ) async -> Bool {
        let outcome = await manager.sessionCoordinator.run(for: self, kind: .botControl) { [weak self] flowID in
            guard let self else { return .cancelled }
            let completed = await self.performBotControl(args: args, using: presenter, flowID: flowID, source: source)
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
        flowID: UUID,
        source: ServiceActionScheduler.BotControlLease?
    ) async -> Bool {
        guard definition.action(Manifest.BOT_CONTROL_URL_ACTION_ID, includingStandard: true) != nil,
              definition.action(Manifest.BOT_CONTROL_STATE_ACTION_ID, includingStandard: true) != nil,
              let episodeArgs = args.objectValue else {
            Log.service.error("Service.completeBotControl unavailable domain=\(domain)")
            return false
        }
        let flowSession: ServiceFlowSession
        do {
            if let source {
                flowSession = try await ServiceFlowSession.adopt(
                    id: flowID,
                    kind: .botControl,
                    service: self,
                    actionID: Manifest.BOT_CONTROL_URL_ACTION_ID,
                    args: args,
                    role: .blockingAction,
                    source: source
                )
            } else {
                flowSession = try await ServiceFlowSession.open(
                    id: flowID,
                    kind: .botControl,
                    service: self,
                    actionID: Manifest.BOT_CONTROL_URL_ACTION_ID,
                    args: args,
                    role: .blockingAction
                )
            }
        } catch {
            Log.service.error("Service.completeBotControl action page unavailable domain=\(domain) source=\(source == nil ? "fresh" : "action-page") error=\(LogPrivacy.text(error.localizedDescription))")
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
        Log.service.info("Service.completeBotControl presenting domain=\(domain) attempt=\(session.handoff.id.uuidString.prefix(8)) source=\(source == nil ? "fresh" : "action-page") session=\(flowSession.actionPage.logLabel)")
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
        handoff = flowSession.makeActionPageHandoff(
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

@MainActor
final class ServiceBotControlSourceStore {
    enum Claim {
        case none
        case mismatch
        case matched(ServiceActionScheduler.BotControlLease)
    }

    private struct Pending {
        let service: Service
        let args: JSONValue
        let lease: ServiceActionScheduler.BotControlLease
    }

    private var pending: Pending?
    private var expiry: Task<Void, Never>?

    func retain(service: Service, args: JSONValue, page: Service.ServiceWebPage) {
        guard let lease = service.manager.actionScheduler.reserveForBotControl(page) else {
            Log.service.warning("ServiceBotControlSourceStore unavailable domain=\(service.domain) session=\(page.logLabel)")
            return
        }
        release()
        pending = Pending(service: service, args: args, lease: lease)
        expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            guard let self else {
                lease.release(discardPage: true)
                return
            }
            guard self.pending?.lease === lease else { return }
            Log.service.info("ServiceBotControlSourceStore expired domain=\(service.domain) session=\(page.logLabel)")
            self.release()
        }
        Log.service.info("ServiceBotControlSourceStore retained domain=\(service.domain) session=\(page.logLabel)")
    }

    func claim(service: Service, args: JSONValue) -> Claim {
        guard let pending, pending.service === service else { return .none }
        guard pending.args == args else { return .mismatch }
        guard pending.lease.isActive else {
            release()
            return .none
        }
        expiry?.cancel()
        expiry = nil
        self.pending = nil
        return .matched(pending.lease)
    }

    func release() {
        expiry?.cancel()
        expiry = nil
        pending?.lease.release(discardPage: true)
        pending = nil
    }
}
