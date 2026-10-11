import Foundation

extension AppPresentations {
    static let live = AppPresentations(
        serviceSignIn: AppPresentationCoordinator.shared,
        serviceHandoff: AppPresentationCoordinator.shared,
        messages: MessageSheetComposer(),
        providerAuthentication: AppPresentationCoordinator.shared
    )
}

@MainActor
private struct MessageSheetComposer: MessageComposing {
    var canSend: Bool { MessageComposer.canSend }

    func present(recipients: [String], body: String?) async throws -> MessageDisposition {
        try await MessageComposer.present(recipients: recipients, body: body)
    }
}
