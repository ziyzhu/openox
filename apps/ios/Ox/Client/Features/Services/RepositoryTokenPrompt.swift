import SwiftUI
import UIKit

@MainActor
final class RepositoryTokenPrompt: NSObject, UIAdaptivePresentationControllerDelegate {
    private let request: SecretEntryRequest
    private var controller: UIViewController?
    private var continuation: CheckedContinuation<Bool, Never>?

    private init(validate: @escaping RepositoryTokenValidation) {
        request = SecretEntryRequest(validate: validate)
    }

    static func present(validate: @escaping RepositoryTokenValidation) async -> Bool {
        let prompt = RepositoryTokenPrompt(validate: validate)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                prompt.continuation = continuation
                prompt.show()
            }
        } onCancel: {
            Task { @MainActor in prompt.finish(false) }
        }
    }

    private func show() {
        guard !Task.isCancelled,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              var presenter = scene.keyWindow?.rootViewController else {
            finish(false)
            return
        }
        while let presented = presenter.presentedViewController { presenter = presented }
        let card = SecretEntryRequestCard(request: request, onSaved: {
            self.finish(true)
        }, onCancel: {
            self.finish(false)
        })
        let controller = UIHostingController(rootView: ScrollView { card.padding() }.themed())
        controller.modalPresentationStyle = .pageSheet
        controller.sheetPresentationController?.detents = [.medium(), .large()]
        controller.sheetPresentationController?.prefersGrabberVisible = true
        controller.presentationController?.delegate = self
        self.controller = controller
        presenter.present(controller, animated: true)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finish(false)
    }

    private func finish(_ accepted: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        request.cancel()
        controller?.dismiss(animated: true)
        controller = nil
        continuation.resume(returning: accepted)
    }
}
