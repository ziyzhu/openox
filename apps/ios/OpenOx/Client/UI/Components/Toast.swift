import SwiftUI
import UIKit

struct Toast: Identifiable, Equatable {
    enum Role {
        case info
        case error
    }

    enum Action: Equatable {
        case openSettings

        var label: String {
            switch self {
            case .openSettings: L10n.string("Open Settings", comment: "")
            }
        }

        @MainActor func perform() {
            switch self {
            case .openSettings:
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
    }

    let id = UUID()
    var message: String
    var role: Role = .info
    var action: Action? = nil
    var duration: TimeInterval = 1.8
}

struct ToastPill: View {
    let toast: Toast
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: toast.role.icon)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(toast.role.iconColor)

            Text(toast.message)
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.onSurface)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)

            if let action = toast.action {
                Button {
                    action.perform()
                    onDismiss()
                } label: {
                    Text(action.label)
                        .font(Theme.Fonts.labelMd)
                        .foregroundStyle(Theme.Colors.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .alertGlassPill(in: toast.role.shape)
        .onTapGesture(perform: onDismiss)
        .accessibilityElement(children: toast.action == nil ? .combine : .contain)
        .accessibilityAddTraits(toast.action == nil ? .isButton : [])
        .accessibilityHint(toast.action == nil ? "Tap to dismiss" : "")
        .accessibilityIdentifier(A11yID.Chat.toast)
    }
}

extension View {
    func alertGlassPill<S: Shape>(in shape: S) -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: shape)
            .contentShape(shape)
    }
}

private extension Toast.Role {
    var icon: String {
        switch self {
        case .info: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var iconColor: DynamicColor {
        switch self {
        case .info: Theme.Colors.primary
        case .error: Theme.Colors.error
        }
    }

    var shape: AnyShape {
        switch self {
        case .info: AnyShape(Capsule())
        case .error: AnyShape(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
        }
    }
}

private struct ToastModifier: ViewModifier {
    @Binding var toast: Toast?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let t = toast {
                    ToastPill(toast: t) {
                        withAnimation(.easeOut(duration: 0.2)) { toast = nil }
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .accessibilityElement(children: .contain)
                }
            }
            .task(id: toast?.id) {
                guard let current = toast, current.role == .info else { return }
                try? await Task.sleep(for: .seconds(current.duration))
                guard !Task.isCancelled, toast?.id == current.id else { return }
                withAnimation(.easeOut(duration: 0.2)) { toast = nil }
            }
    }
}

extension View {
    func toast(_ toast: Binding<Toast?>) -> some View {
        modifier(ToastModifier(toast: toast))
    }
}

#Preview("Toast pill variants") {
    VStack(spacing: Theme.Spacing.md) {
        ToastPill(toast: Toast(message: "Message copied")) {}
        ToastPill(toast: Toast(message: "Network error — check your connection and try again.", role: .error)) {}
        ToastPill(toast: Toast(message: "HTTP 429: insufficient balance or no resource package. Please recharge.", role: .error)) {}
    }
    .padding(Theme.Spacing.md)
    .background(Theme.Colors.surface)
}
