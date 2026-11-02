import SwiftUI

struct ServiceControlView: View {
    let control: ServiceControl
    var isActive: Bool = true
    var reflectsAuthentication: Bool = true
    let login: @MainActor (String) async -> Bool
    let onResolved: (JSONValue?) -> Void

    @Environment(ServiceManager.self) private var serviceManager
    @State private var phase: Phase = .ready

    private enum Phase {
        case ready
        case working
        case completed
    }

    private var domain: String { control.domain }
    private var service: Service? { serviceManager.service(domain: domain) }
    private var name: String {
        let suppliedName: String? = switch control {
        case .login(_, let name), .botControl(_, let name, _), .payment(_, let name, _): name
        }
        return suppliedName ?? service?.title ?? domain
    }
    private var isLogin: Bool {
        if case .login = control { return true }
        return false
    }
    private var completed: Bool {
        phase == .completed || reflectsAuthentication && service?.loginState.isAuthenticated == true
    }
    private var isMCP: Bool { service?.isMCPService == true }

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            identity
            Spacer(minLength: Theme.Spacing.sm)
            if isLogin, isActive, !completed {
                HStack(spacing: Theme.Spacing.sm) {
                    if phase == .ready {
                        RequestPillButton(title: String(localized: "Dismiss"), isPrimary: false) {
                            onResolved(nil)
                        }
                        .accessibilityIdentifier(A11yID.ConversationControls.Attach.loginDismiss(domain))
                    }
                    ServiceLoginButton(
                        loggingIn: phase == .working,
                        isDisabled: phase == .working,
                        layout: .prompt,
                        action: run
                    )
                    .accessibilityIdentifier(
                        phase == .working
                            ? A11yID.ConversationControls.Attach.loginProgress(domain)
                            : A11yID.ConversationControls.Attach.login(domain)
                    )
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(minHeight: Theme.Size.minimumTouchTarget)
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
                ServiceAvatar(service: service, size: 34, shape: .roundedRect(Theme.Radius.sm))
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
        case .login: "person.badge.key.fill"
        case .botControl: "checkmark.shield.fill"
        case .payment: "creditcard.fill"
        }
    }

    private var message: String {
        switch control {
        case .login:
            if !isActive { return isMCP ? String(localized: "Authorize") : String(localized: "Log in") }
            if completed { return isMCP ? String(localized: "Authorized") : String(localized: "You're logged in") }
            return isMCP ? String(localized: "Authorize to continue") : String(localized: "Log in to continue")
        case .botControl: return String(localized: "Verify")
        case .payment: return String(localized: "Pay")
        }
    }

    private func run() {
        guard isLogin, isActive, phase == .ready else { return }
        phase = .working
        Task {
            let result: JSONValue? = await login(domain) ? .null : nil
            phase = result != nil ? .completed : .ready
            onResolved(result)
        }
    }
}
