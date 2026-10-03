import SwiftUI

struct HostSettingsSection: View {
    @Environment(HostAccess.self) private var access

    var body: some View {
        SettingsSection("Host", footer: "Connect through Tailscale while Ox is open.", layout: .row) {
            Toggle("Allow connections", isOn: Binding(get: { access.enabled }, set: { access.enabled = $0 }))
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurface)
                .tint(Theme.Colors.primary)
                .settingsRowPadding()
                .accessibilityIdentifier(A11yID.Settings.hostEnabled)
        }
    }
}
