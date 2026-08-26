import MessageUI
import UIKit

@MainActor
final class MessageComposer: NSObject, MFMessageComposeViewControllerDelegate {
    private var continuation: CheckedContinuation<MessageDisposition, Error>?
    private var retain: MessageComposer?
    private weak var controller: MFMessageComposeViewController?

    static var canSend: Bool { MFMessageComposeViewController.canSendText() }

    static func present(recipients: [String], body: String?) async throws -> MessageDisposition {
        guard canSend else { throw MessageComposeError.unavailable }
        return try await MessageComposer().run(recipients: recipients, body: body)
    }

    private func run(recipients: [String], body: String?) async throws -> MessageDisposition {
        try Task.checkCancellation()
        guard let presenter = Self.topViewController() else { throw MessageComposeError.noPresenter }
        retain = self
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                self.continuation = cont
                guard !Task.isCancelled else { finish(.failure(CancellationError())); return }
                let vc = MFMessageComposeViewController()
                controller = vc
                vc.messageComposeDelegate = self
                if !recipients.isEmpty { vc.recipients = recipients }
                if let body, !body.isEmpty { vc.body = body }
                Log.ui.info("MessageComposer.present recipients=\(recipients.count) hasBody=\(body?.isEmpty == false)")
                presenter.present(vc, animated: true)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
        let disposition: MessageDisposition = {
            switch result {
            case .sent: return .sent
            case .cancelled: return .cancelled
            case .failed: return .failed
            @unknown default: return .failed
            }
        }()
        Log.ui.info("MessageComposer.finished result=\(disposition.rawValue)")
        finish(.success(disposition))
    }

    private func finish(_ result: Result<MessageDisposition, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        let complete = {
            continuation.resume(with: result)
            self.retain = nil
        }
        if let controller { controller.dismiss(animated: true, completion: complete) }
        else { complete() }
        controller = nil
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let root = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
                ?? scene?.windows.first?.rootViewController else { return nil }
        var top: UIViewController = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}
