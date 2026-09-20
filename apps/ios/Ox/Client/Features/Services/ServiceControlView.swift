import SwiftUI

struct InlineBotControlView: View {
    let control: ServiceControl
    let session: ServiceHandoffSession?
    let isPresentedInSheet: Bool
    let expand: (ServiceHandoffSession) -> Void
    let cancel: (ServiceHandoffSession) -> Void

    @Environment(ServiceManager.self) private var serviceManager

    private var domain: String { control.domain }

    private var suppliedName: String? {
        guard case .botControl(_, let serviceName, _) = control else { return nil }
        return serviceName
    }

    private var service: Service? { serviceManager.service(domain: domain) }
    private var name: String { suppliedName ?? service?.title ?? domain }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .stroke(Theme.Colors.onSurfaceMuted.opacity(0.18), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.md) {
            if let service {
                ServiceAvatar(
                    service: service,
                    size: 34,
                    shape: .roundedRect(Theme.Radius.sm)
                )
            } else {
                Image(systemName: "checkmark.shield.fill")
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
                    .accessibilityIdentifier(A11yID.Chat.Attach.botControl(domain))
                Text("Complete the site's human verification to continue")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: Theme.Spacing.sm)
            if let session {
                HStack(spacing: Theme.Spacing.sm) {
                    Button { expand(session) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.Colors.onSurface)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityLabel("View live page")
                    .accessibilityIdentifier(A11yID.Chat.Attach.botControlExpand(domain))
                    Button { cancel(session) } label: {
                        Image(systemName: "xmark")
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.Colors.onSurface)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityLabel("Cancel")
                    .accessibilityIdentifier(A11yID.Chat.Attach.botControlCancel(domain))
                }
            }
        }
        .frame(minHeight: Theme.Size.minimumTouchTarget)
        .padding(.leading, Theme.Spacing.md)
        .padding(.trailing, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.sm)
    }

    @ViewBuilder
    private var content: some View {
        if let session, !isPresentedInSheet {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    WebContentView(page: session.page)
                }
        } else {
            VStack(spacing: Theme.Spacing.md) {
                ProgressView()
                Text("Complete the site's human verification to continue")
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .padding(.horizontal, Theme.Spacing.xl)
        }
    }
}

struct ServiceControlView: View {
    let control: ServiceControl
    var isActive: Bool = true
    var reflectsAuthentication: Bool = true
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

    private var completed: Bool { phase == .completed || reflectsAuthentication && authenticated }
    private var isMCP: Bool { service?.isMCPService == true }

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            identity
            Spacer(minLength: Theme.Spacing.sm)
            HStack(spacing: Theme.Spacing.sm) {
                if isActive, !completed, phase == .ready, case .signIn = control {
                    RequestPillButton(title: String(localized: "Dismiss"), isPrimary: false) {
                        onResolved(nil)
                    }
                    .accessibilityIdentifier(A11yID.Chat.Attach.signInDismiss(domain))
                }
                if case .signIn = control {
                    action
                } else {
                    action.frame(width: 108, alignment: .trailing)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
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
                ServiceAvatar(
                    service: service,
                    size: 34,
                    shape: .roundedRect(Theme.Radius.sm)
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
        if !isActive {
            actionLabel
        } else if completed {
            switch control {
            case .signIn: isMCP ? String(localized: "Authorized") : String(localized: "You're signed in")
            case .botControl: String(localized: "Verification completed")
            case .payment: String(localized: "Payment completed")
            }
        } else {
            switch control {
            case .signIn: isMCP ? String(localized: "Authorize to continue") : String(localized: "Sign in to continue")
            case .botControl: String(localized: "Complete the site's human verification to continue")
            case .payment: String(localized: "Review and complete the payment on the service")
            }
        }
    }

    @ViewBuilder
    private var action: some View {
        if !isActive {
            EmptyView()
        } else if completed {
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
        guard isActive, phase == .ready else { return }
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
