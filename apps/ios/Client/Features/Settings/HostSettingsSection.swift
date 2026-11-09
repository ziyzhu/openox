import SwiftUI

struct HostSettingsSection: View {
    @Environment(HostAccess.self) private var access

    private var selectedHostName: Text {
        switch access.selection {
        case .local:
            return Text(HostPickerView.localTitle)
        case .remote(let endpoint):
            return Text(verbatim: access.remoteHosts.first { $0.endpoint == endpoint }?.name ?? "")
        }
    }

    var body: some View {
        SettingsSection(footer: "Off by default. Allow other devices on your Tailscale network to connect to Ox, manage conversations, and run tools. Keep Ox open while connected. Only enable this on a trusted network.", layout: .group) {
            VStack(spacing: 0) {
                NavigationLink {
                    HostPickerView()
                } label: {
                    SettingsDisclosureRow(title: "Ox Host", value: selectedHostName)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(A11yID.Settings.hostPicker)

                Divider().settingsContentInset()

                Toggle("Host", isOn: Binding(get: { access.enabled }, set: { access.enabled = $0 }))
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .tint(Theme.Colors.primary)
                    .settingsRowPadding()
                    .accessibilityIdentifier(A11yID.Settings.hostEnabled)
            }
        }
    }
}
