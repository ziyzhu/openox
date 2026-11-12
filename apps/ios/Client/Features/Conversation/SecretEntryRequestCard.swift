import SwiftUI

struct SecretEntryRequestCard: View {
    let request: SecretEntryRequest
    let onSaved: () -> Void
    let onCancel: () -> Void

    @Environment(ServiceManager.self) private var serviceManager
    @State private var values: [String: String]

    init(request: SecretEntryRequest, onSaved: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.request = request
        self.onSaved = onSaved
        self.onCancel = onCancel
        _values = State(initialValue: request.spec.prefill)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                if let domain = request.spec.serviceDomain, let service = serviceManager.service(domain: domain) {
                    ServiceAvatar(service: service, size: 34, shape: .roundedRect(Theme.Radius.sm))
                }
                Text(summary)
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SecretTypedFieldsEditor(type: request.spec.type, values: $values)
                .padding(.horizontal, Theme.Spacing.md)
                .background(Theme.Colors.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                .disabled(request.state != .editing)
            if let message = request.error {
                Text(message)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.error.dynamic)
            }
            HStack(spacing: Theme.Spacing.sm) {
                RequestPillButton(title: String(localized: "Don't Save"), isPrimary: false, fillsWidth: true) {
                    request.cancel()
                    values.removeAll()
                    onCancel()
                }
                .accessibilityIdentifier("secret-entry-dont-save")
                RequestPillButton(
                    title: String(localized: "Save"),
                    isPrimary: true,
                    isLoading: request.state == .saving,
                    fillsWidth: true,
                    action: save
                )
                .disabled(!request.spec.type.isComplete(values) || request.state != .editing)
                .accessibilityIdentifier("secret-entry-save")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.lg)
        .conversationCardOutline()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("secret-entry-card")
    }

    private var summary: String {
        let target = request.spec.serviceDomain ?? request.key
        if request.spec.type == .account, !request.spec.prefill.isEmpty {
            return String(localized: "Remember this login for \(target)? Ox uses it only to sign in there, and never shows it to the conversation.")
        }
        return switch request.spec.type {
        case .account: String(localized: "Save a login for \(target). Ox uses it only to sign in there, and never shows it to the conversation.")
        case .apiKey: String(localized: "Save an API key for \(target). Ox sends it only to \(target), and never shows it to the conversation.")
        case .token: String(localized: "Save a token for \(target). Ox sends it only to \(target), and never shows it to the conversation.")
        }
    }

    private func save() {
        request.submit(values: values) {
            values.removeAll()
            onSaved()
        }
    }
}
