import SwiftUI

struct HostSettingsSection: View {
    @Environment(HostAccess.self) private var access

    var body: some View {
        SettingsSection("Host", footer: "Off by default. Allow other devices on your Tailscale network to connect to Ox, manage chats, and run tools. Keep Ox open while connected. Only enable this on a trusted network.", layout: .row) {
            Toggle("Allow connections", isOn: Binding(get: { access.enabled }, set: { access.enabled = $0 }))
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurface)
                .tint(Theme.Colors.primary)
                .settingsRowPadding()
                .accessibilityIdentifier(A11yID.Settings.hostEnabled)
        }
    }
}
