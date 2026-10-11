import SwiftUI

struct ServiceSignInButton: View {
    enum Layout {
        case compact
        case prompt
    }

    let signingIn: Bool
    let isDisabled: Bool
    let layout: Layout
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        switch layout {
        case .compact:
            button
                .buttonStyle(OxChipButton(filled: true))
        case .prompt:
            button
                .buttonStyle(RequestButtonStyle())
        }
    }

    private var button: some View {
        Button(action: action) {
            label
        }
        .disabled(isDisabled)
    }

    @ViewBuilder
    private var label: some View {
        switch layout {
        case .compact:
            content
                .frame(minWidth: 48)
                .frame(minHeight: 18)
        case .prompt:
            content
                .frame(minWidth: 72)
                .frame(minHeight: 36)
                .background(Theme.Colors.primary, in: Capsule(style: .continuous))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private var content: some View {
        if signingIn {
            CellularAutomatonLoader(size: 16, tint: Theme.Colors.onPrimary.dynamic)
                .accessibilityLabel(String(localized: "Signing in…"))
        } else {
            Text("Sign in")
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.onPrimary)
                .lineLimit(1)
        }
    }
}
