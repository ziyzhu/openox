import UIKit

@MainActor
final class RepositoryTokenPrompt {
    private var alert: UIAlertController?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var validationTask: Task<Void, Never>?

    static func present(validate: @escaping RepositoryTokenValidation) async -> Bool {
        let prompt = RepositoryTokenPrompt()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                prompt.continuation = continuation
                prompt.show(validate: validate)
            }
        } onCancel: {
            Task { @MainActor in prompt.finish(false) }
        }
    }

    private func show(validate: @escaping RepositoryTokenValidation) {
        guard !Task.isCancelled,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              var presenter = scene.keyWindow?.rootViewController else {
            finish(false)
            return
        }
        while let presented = presenter.presentedViewController { presenter = presented }
        let alert = UIAlertController(
            title: String(localized: "GitHub personal access token"),
            message: String(localized: "Use a classic token with public_repo access. It is saved in Keychain and never sent to the model. After creating a token, return to Ox and propose again."),
            preferredStyle: .alert
        )
        self.alert = alert
        alert.addTextField { field in
            field.placeholder = "ghp_…"
            field.isSecureTextEntry = true
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.accessibilityIdentifier = "repository.github.token"
        }
        alert.addAction(UIAlertAction(title: String(localized: "Create token"), style: .default) { _ in
            UIApplication.shared.open(URL(string: "https://github.com/settings/tokens/new?scopes=public_repo&description=OpenOx")!)
            self.finish(false)
        })
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in self.finish(false) })
        alert.addAction(UIAlertAction(title: String(localized: "Continue"), style: .default) { [weak alert] _ in
            let token = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            alert?.textFields?.first?.text = nil
            self.validationTask = Task {
                do {
                    try await validate(token)
                    try Task.checkCancellation()
                    self.finish(true)
                } catch is CancellationError {
                    self.finish(false)
                } catch {
                    guard self.continuation != nil else { return }
                    self.showError(error.localizedDescription, presenter: presenter, validate: validate)
                }
            }
        })
        presenter.present(alert, animated: true)
    }

    private func showError(_ message: String, presenter: UIViewController, validate: @escaping RepositoryTokenValidation) {
        let failure = UIAlertController(title: String(localized: "GitHub personal access token"), message: message, preferredStyle: .alert)
        alert = failure
        failure.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in self.finish(false) })
        failure.addAction(UIAlertAction(title: String(localized: "Try Again"), style: .default) { [weak failure] _ in
            failure?.dismiss(animated: true) { self.show(validate: validate) }
        })
        presenter.dismiss(animated: true) {
            guard self.continuation != nil else { return }
            presenter.present(failure, animated: true)
        }
    }

    private func finish(_ accepted: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        validationTask?.cancel()
        validationTask = nil
        alert?.textFields?.first?.text = nil
        alert?.dismiss(animated: true)
        alert = nil
        continuation.resume(returning: accepted)
    }
}
