import SwiftUI
import UIKit

struct NotificationSetupView: View {
    var body: some View {
        ScrollView {
            NotificationSetupContent()
                .frame(maxWidth: 560)
                .padding(Theme.Spacing.xxl)
        }
        .background(Theme.Colors.background)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct NotificationSetupContent: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var permissionState: NativePermissionState?
    @State private var updating = false

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            VStack(spacing: Theme.Spacing.md) {
                Text("Stay notified")
                    .font(Theme.Fonts.display)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .fixedSize(horizontal: false, vertical: true)

                Text(message)
                    .font(Theme.Fonts.bodyMd)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            permissionControl
        }
        .task { await refreshPermission() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshPermission() }
        }
    }

    @ViewBuilder
    private var permissionControl: some View {
        switch permissionState {
        case .notDetermined, nil:
            VStack(spacing: Theme.Spacing.lg) {
                NotificationPermissionCard(updating: updating, onAllow: updatePermission)

                HStack(spacing: Theme.Spacing.md) {
                    Color.clear
                        .frame(maxWidth: .infinity)

                    Image(systemName: "chevron.up")
                        .font(Theme.Icons.sm)
                        .foregroundStyle(Theme.Colors.onSurface)
                        .frame(maxWidth: .infinity)
                }
                .frame(height: Theme.Spacing.md)
                .padding(.horizontal, Theme.Spacing.md)
                .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
        case .granted:
            Text("Notifications are already on")
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(A11yID.NotificationSetup.permission)
        case .denied:
            Button(action: updatePermission) {
                if updating {
                    CellularAutomatonLoader.small
                        .frame(minWidth: 180)
                } else {
                    Label("Open Notification Settings", systemImage: "gear")
                        .frame(minWidth: 180)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.Colors.primary)
            .disabled(updating)
            .accessibilityIdentifier(A11yID.NotificationSetup.permission)
        }
    }

    private var message: LocalizedStringKey {
        switch permissionState {
        case .granted:
            "Ox will notify you when longer requests and background tasks finish."
        case .denied:
            "Notifications are off. Open Settings so Ox can tell you when longer requests and background tasks finish."
        case .notDetermined, nil:
            "Get updates from Ox, even when you’re away."
        }
    }

    private func updatePermission() {
        guard !updating else { return }
        updating = true
        Task {
            let current = await NativePermission.notifications.state()
            if current == .denied {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    _ = await UIApplication.shared.open(url)
                }
            } else {
                permissionState = await NativePermission.notifications.request()
            }
            await refreshPermission()
            updating = false
            Log.ui.info("Notifications.permission state=\(String(describing: permissionState))")
        }
    }

    private func refreshPermission() async {
        permissionState = await NativePermission.notifications.state()
    }
}

private struct NotificationPermissionCard: View {
    let updating: Bool
    let onAllow: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("“Ox” Would Like to Send You Notifications")
                .font(Theme.Fonts.title)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(Theme.Colors.onSurface)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.top, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.lg)

            HStack(spacing: Theme.Spacing.md) {
                NotificationPromptControl(title: "Don’t Allow", isPrimary: false)

                Button(action: onAllow) {
                    if updating {
                        CellularAutomatonLoader.small
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    } else {
                        NotificationPromptControl(title: "Allow", isPrimary: true)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .disabled(updating)
                .accessibilityLabel(Text("Allow Notifications"))
                .accessibilityIdentifier(A11yID.NotificationSetup.permission)
            }
            .padding(Theme.Spacing.md)
        }
        .background {
            Color.clear.glassEffect(
                .regular.tint(Theme.Colors.surface.dynamic),
                in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
            )
        }
    }
}

private struct NotificationPromptControl: View {
    let title: LocalizedStringKey
    let isPrimary: Bool

    var body: some View {
        Text(title)
            .font(Theme.Fonts.title)
            .foregroundStyle(isPrimary ? .white : Theme.Colors.onSurface.dynamic)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .background(
                isPrimary ? Color(uiColor: .systemBlue) : Theme.Colors.surfaceSunken.dynamic,
                in: Capsule()
            )
    }
}
