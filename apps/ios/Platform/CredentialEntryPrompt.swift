import SafariServices
import UIKit

@MainActor
final class CredentialEntryPrompt: NSObject, SFSafariViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
    struct Field {
        let label: String
        let value: String
        let secure: Bool
        let contentType: UITextContentType?
        let accessibilityIdentifier: String
    }

    struct Website {
        let url: URL
        let label: String
        let accessibilityIdentifier: String
    }

    private var accessibilityIdentifier = ""
    private var continuation: CheckedContinuation<[String], Error>?
    private weak var presenter: UIViewController?
    private var alert: UIAlertController?
    private var browser: SFSafariViewController?
    private var save: UIAlertAction?
    private var validate: (([String]) -> Bool)?

    static func enter(title: String, fields: [Field], website: Website?, accessibilityIdentifier: String, validate: @escaping ([String]) -> Bool) async throws -> [String] {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              var presenter = scene.keyWindow?.rootViewController else { throw CancellationError() }
        while let presented = presenter.presentedViewController { presenter = presented }
        let prompt = CredentialEntryPrompt()
        return try await prompt.present(from: presenter, title: title, fields: fields, website: website, accessibilityIdentifier: accessibilityIdentifier, validate: validate)
    }

    private func present(from presenter: UIViewController, title: String, fields: [Field], website: Website?, accessibilityIdentifier: String, validate: @escaping ([String]) -> Bool) async throws -> [String] {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.accessibilityIdentifier = accessibilityIdentifier
                Log.ui.info("CredentialEntry.present id=\(accessibilityIdentifier) fields=\(fields.count) website=\(website != nil)")
                self.continuation = continuation
                self.presenter = presenter
                self.validate = validate
                let alert = UIAlertController(title: title, message: String(localized: "Authentication"), preferredStyle: .alert)
                alert.view.accessibilityIdentifier = accessibilityIdentifier
                self.alert = alert
                for entry in fields {
                    alert.addTextField { field in
                        field.placeholder = entry.label
                        field.text = entry.value
                        field.isSecureTextEntry = entry.secure
                        field.textContentType = entry.contentType
                        field.autocapitalizationType = .none
                        field.autocorrectionType = .no
                        field.accessibilityIdentifier = entry.accessibilityIdentifier
                        field.addTarget(self, action: #selector(self.refreshSave), for: .editingChanged)
                    }
                }
                if let website {
                    let action = UIAlertAction(title: website.label, style: .default) { _ in
                        alert.dismiss(animated: true) {
                            guard self.continuation != nil else { return }
                            Log.ui.info("CredentialEntry.browser id=\(accessibilityIdentifier)")
                            let browser = SFSafariViewController(url: website.url)
                            browser.delegate = self
                            self.browser = browser
                            presenter.present(browser, animated: true)
                            browser.presentationController?.delegate = self
                        }
                    }
                    action.accessibilityIdentifier = website.accessibilityIdentifier
                    alert.addAction(action)
                }
                let cancel = UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in
                    self.finish(.failure(CancellationError()))
                }
                cancel.accessibilityIdentifier = accessibilityIdentifier + ".cancel"
                alert.addAction(cancel)
                let save = UIAlertAction(title: String(localized: "Save"), style: .default) { _ in
                    self.finish(.success(self.values))
                }
                save.accessibilityIdentifier = accessibilityIdentifier + ".save"
                self.save = save
                alert.addAction(save)
                refreshSave()
                presenter.present(alert, animated: true)
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private var values: [String] { alert?.textFields?.map { $0.text ?? "" } ?? [] }

    @objc private func refreshSave() { save?.isEnabled = validate?(values) == true }

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        controller.dismiss(animated: true) { self.resumeEntry() }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { resumeEntry() }

    private func resumeEntry() {
        browser = nil
        Log.ui.info("CredentialEntry.return id=\(accessibilityIdentifier)")
        guard continuation != nil, let alert else { return }
        presenter?.present(alert, animated: true)
    }

    private func finish(_ result: Result<[String], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        let outcome = switch result {
        case .success: "saved"
        case .failure: "cancelled"
        }
        Log.ui.info("CredentialEntry.complete id=\(accessibilityIdentifier) outcome=\(outcome)")
        let controller: UIViewController? = browser ?? alert
        browser = nil
        alert = nil
        save = nil
        validate = nil
        if controller?.presentingViewController != nil {
            controller?.dismiss(animated: true) { continuation.resume(with: result) }
        } else {
            continuation.resume(with: result)
        }
    }
}
