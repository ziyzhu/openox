import Foundation

extension Service {
    func completePayment(args: JSONValue, using presenter: any ServiceHandoffPresenting) async -> JSONValue? {
        let outcome = await manager.sessionCoordinator.run(for: self, kind: .payment) { [weak self] flowID in
            guard let self else { return .cancelled }
            guard let result = await self.performPayment(args: args, using: presenter, flowID: flowID) else {
                return .cancelled
            }
            return .payment(result)
        }
        if case .payment(let result) = outcome { return result }
        return nil
    }

    private func performPayment(
        args: JSONValue,
        using presenter: any ServiceHandoffPresenting,
        flowID: UUID
    ) async -> JSONValue? {
        guard let urlAction = definition.action(Manifest.PAYMENT_URL_ACTION_ID, includingStandard: true),
              let stateAction = definition.action(Manifest.PAYMENT_STATE_ACTION_ID, includingStandard: true),
              args.objectValue != nil else {
            Log.service.error("Service.completePayment unavailable domain=\(domain)")
            return nil
        }
        let urlArgs = paymentArgs(args, for: urlAction)
        var stateArgs = paymentArgs(args, for: stateAction)
        if stateAction.inputSchema?.objectValue?["properties"]?.objectValue?["since"] != nil,
           stateArgs.objectValue?["since"] == nil,
           case .object(var fields) = stateArgs {
            fields["since"] = .string(Self.paymentStart())
            stateArgs = .object(fields)
        }
        guard let flowSession = try? await ServiceFlowSession.open(
            id: flowID,
            kind: .payment,
            service: self,
            actionID: Manifest.PAYMENT_URL_ACTION_ID,
            args: urlArgs,
            role: .blockingAction
        ) else {
            Log.service.error("Service.completePayment action page unavailable domain=\(domain)")
            return nil
        }
        defer { flowSession.close() }
        let urlResult = await flowSession.invoke(
            Manifest.PAYMENT_URL_ACTION_ID,
            args: urlArgs,
            role: .blockingAction
        )
        guard case .success(let value) = urlResult,
              let rawURL = Manifest.authURL(value),
              let url = URL(string: rawURL),
              ServiceHandoffSession.allowsNavigation(to: url) else {
            Log.service.error("Service.completePayment invalid URL domain=\(domain)")
            return nil
        }
        let session = ServicePaymentSession(service: self, url: url, args: stateArgs, flowSession: flowSession)
        Log.service.info("Service.completePayment presenting domain=\(domain) attempt=\(session.handoff.id.uuidString.prefix(8))")
        let result = await session.present(using: presenter)
        Log.service.info("Service.completePayment done domain=\(domain) completed=\(result != nil)")
        return result
    }

    private func paymentArgs(_ args: JSONValue, for action: Manifest.Action) -> JSONValue {
        guard let fields = args.objectValue,
              let properties = action.inputSchema?.objectValue?["properties"]?.objectValue else { return args }
        return .object(fields.filter { properties[$0.key] != nil })
    }

    private static func paymentStart() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}

@MainActor
final class ServicePaymentSession {
    private final class ResultBox {
        var value: JSONValue?
    }

    let handoff: ServiceHandoffSession

    private weak var service: Service?
    private let flowSession: ServiceFlowSession
    private let completedState: ResultBox

    init(service: Service, url: URL, args: JSONValue, flowSession: ServiceFlowSession) {
        let completedState = ResultBox()
        self.service = service
        self.flowSession = flowSession
        self.completedState = completedState
        handoff = flowSession.makeHandoff(
            title: service.title,
            navigationTitle: String(localized: "Checkout"),
            initialURL: url,
            completionProbe: { [weak flowSession] _ in
                guard let flowSession else { return false }
                let result = await flowSession.invoke(
                    Manifest.PAYMENT_STATE_ACTION_ID,
                    args: args,
                    role: .blockingAction
                )
                guard case .success(let value) = result,
                      value.objectValue?["status"]?.stringValue == "completed",
                      value.objectValue?["reference"]?.stringValue?.isEmpty == false else { return false }
                completedState.value = value
                return true
            }
        )
    }

    func present(using presenter: any ServiceHandoffPresenting) async -> JSONValue? {
        guard await presenter.present(session: handoff) == .completed, service != nil else { return nil }
        return completedState.value
    }
}
