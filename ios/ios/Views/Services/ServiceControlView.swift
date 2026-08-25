import SwiftUI

struct ServiceControlView: View {
    let control: ServiceControl
    let signIn: @MainActor (String) async -> Bool
    let completeBotControl: @MainActor (String, JSONValue) async -> Bool
    let completePayment: @MainActor (String, JSONValue) async -> JSONValue?
    let onResolved: (JSONValue?) -> Void

    @Environment(ServiceManager.self) private var serviceManager
    @State private var phase: Phase = .ready

    private enum Phase {
        case ready
        case working
        case completed
    }

    private var domain: String { control.domain }

    private var suppliedName: String? {
        switch control {
        case .signIn(_, let serviceName), .botControl(_, let serviceName, _), .payment(_, let serviceName, _): serviceName
        }
    }

    private var service: Service? { serviceManager.service(domain: domain) }

    private var name: String { suppliedName ?? service?.title ?? domain }

    private var authenticated: Bool {
        if case .signIn = control {
            return service?.signInState.isAuthenticated == true
        }
        return false
    }

    private var completed: Bool { phase == .completed || authenticated }
    private var isMCP: Bool { service?.isMCPService == true }

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            identity
            Spacer(minLength: Theme.Spacing.sm)
            action.frame(width: 108, alignment: .trailing)
        }
        .padding(Theme.Spacing.md)
        .background {
            Color.clear.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
            )
        }
        .accessibilityElement(children: .contain)
    }

    private var identity: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if let service {
                ServiceAvatar(
                    service: service,
                    size: 34,
                    shape: .roundedRect(Theme.Radius.sm),
                    monogramSize: 15
                )
            } else {
                Image(systemName: fallbackIconName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.Colors.primary.dynamic)
                    .frame(width: 34, height: 34)
                    .background(
                        Theme.Colors.primary.dynamic.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    )
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(Theme.Fonts.labelMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .lineLimit(1)
                Text(message)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .lineLimit(2)
            }
        }
    }

    private var fallbackIconName: String {
        switch control {
        case .signIn: "person.badge.key.fill"
        case .botControl: "checkmark.shield.fill"
        case .payment: "creditcard.fill"
        }
    }

    private var message: String {
        if completed {
            switch control {
            case .signIn: isMCP ? String(localized: "Authorized") : String(localized: "You're signed in")
            case .botControl: String(localized: "Verification completed")
            case .payment: String(localized: "Payment completed")
            }
        } else {
            switch control {
            case .signIn: isMCP ? String(localized: "Authorize to continue") : String(localized: "Sign in to continue")
            case .botControl: String(localized: "Complete the site's human verification to continue")
            case .payment: String(localized: "Review and complete the payment in the plugin")
            }
        }
    }

    @ViewBuilder
    private var action: some View {
        if completed {
            switch control {
            case .signIn:
                EmptyView()
            case .botControl:
                Label(String(localized: "Verified"), systemImage: "checkmark")
                    .font(Theme.Fonts.labelMd)
                    .foregroundStyle(Theme.Colors.primary.dynamic)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityValue(String(localized: "Selected"))
                    .accessibilityAddTraits(.isSelected)
            case .payment:
                Label(String(localized: "Completed"), systemImage: "checkmark")
                    .font(Theme.Fonts.labelMd)
                    .foregroundStyle(Theme.Colors.primary.dynamic)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityValue(String(localized: "Selected"))
                    .accessibilityAddTraits(.isSelected)
            }
        } else if case .signIn = control {
            ServiceSignInButton(
                signingIn: phase == .working,
                isDisabled: phase == .working,
                layout: .prompt,
                action: run
            )
            .accessibilityIdentifier(
                phase == .working
                    ? A11yID.Chat.Attach.signInProgress(domain)
                    : accessibilityIdentifier
            )
        } else {
            RequestPillButton(
                title: actionLabel,
                isPrimary: true,
                isLoading: phase == .working,
                loadingLabel: control.isPayment ? String(localized: "Checking out…") : String(localized: "Verifying…"),
                action: run
            )
                .disabled(phase == .working)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
    }

    private var actionLabel: String {
        switch control {
        case .signIn: isMCP ? String(localized: "Authorize") : String(localized: "Sign in")
        case .botControl: String(localized: "Verify")
        case .payment: String(localized: "Pay")
        }
    }

    private var accessibilityIdentifier: String {
        switch control {
        case .signIn: A11yID.Chat.Attach.signIn(domain)
        case .botControl: A11yID.Chat.Attach.botControl(domain)
        case .payment: A11yID.Chat.Attach.payment(domain)
        }
    }

    private func run() {
        phase = .working
        Task {
            let result: JSONValue?
            switch control {
            case .signIn(let domain, _):
                result = await signIn(domain) ? .null : nil
            case .botControl(let domain, _, let args):
                result = await completeBotControl(domain, args) ? .null : nil
            case .payment(let domain, _, let args):
                result = await completePayment(domain, args)
            }
            phase = result != nil ? .completed : .ready
            onResolved(result)
        }
    }
}

private extension ServiceControl {
    var isPayment: Bool {
        if case .payment = self { return true }
        return false
    }
}
