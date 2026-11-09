import SwiftUI

extension View {
    func errorAlert(
        _ title: LocalizedStringKey,
        message: String?,
        dismissIdentifier: String = "alert.error.dismiss",
        dismiss: @escaping () -> Void
    ) -> some View {
        alert(title, isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { dismiss() } }
        )) {
            Button("OK", role: .cancel) {}
                .accessibilityIdentifier(dismissIdentifier)
        } message: {
            Text(verbatim: message ?? "")
        }
    }

    func errorAlert(
        _ title: LocalizedStringKey,
        message: Binding<String?>,
        dismissIdentifier: String = "alert.error.dismiss"
    ) -> some View {
        errorAlert(title, message: message.wrappedValue, dismissIdentifier: dismissIdentifier) {
            message.wrappedValue = nil
        }
    }
}
