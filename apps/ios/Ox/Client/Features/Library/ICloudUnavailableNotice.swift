import SwiftUI

struct ICloudUnavailableNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: "icloud.slash")
                .font(.system(.body, weight: .medium))
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("Not signed in to iCloud")
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                Text("Sign in to iCloud in the Settings app to keep Profiles in the cloud and sync them across your devices.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .settingsRowPadding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsSurface()
        .accessibilityElement(children: .combine)
    }
}
