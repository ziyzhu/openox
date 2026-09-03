import SwiftUI

enum SettingsLayout {
    static let horizontalInset: CGFloat = 20
    static let rowVerticalInset: CGFloat = 14
    static let headerSpacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 32
    static let pageVerticalInset: CGFloat = 16
}

struct SettingsSurfaceShape: Shape {
    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
            .path(in: rect)
    }
}

extension View {
    func settingsSurface(singleRow: Bool = false) -> some View {
        let shape = singleRow
            ? AnyShape(DefaultGlassEffectShape())
            : AnyShape(SettingsSurfaceShape())
        return background(Theme.Colors.surface, in: shape)
    }

    func settingsSectionHeaderInset() -> some View {
        settingsContentInset()
    }

    func settingsContentInset() -> some View {
        padding(.horizontal, SettingsLayout.horizontalInset)
    }

    func settingsRowPadding(_ isEnabled: Bool = true) -> some View {
        padding(.horizontal, isEnabled ? SettingsLayout.horizontalInset : 0)
            .padding(.vertical, isEnabled ? SettingsLayout.rowVerticalInset : 0)
    }

    func settingsPagePadding() -> some View {
        padding(.horizontal, SettingsLayout.horizontalInset)
            .padding(.vertical, SettingsLayout.pageVerticalInset)
    }
}

struct SettingsSection<Content: View>: View {
    let header: LocalizedStringKey
    let footer: LocalizedStringKey?
    let insetContent: Bool
    let content: Content

    init(
        _ header: LocalizedStringKey,
        footer: LocalizedStringKey? = nil,
        insetContent: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.header = header
        self.footer = footer
        self.insetContent = insetContent
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.headerSpacing) {
            Text(header)
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .settingsSectionHeaderInset()

            content
                .settingsRowPadding(insetContent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsSurface(singleRow: insetContent)

            if let footer {
                Text(footer)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .settingsContentInset()
            }
        }
    }
}

struct SettingsDisclosureRow: View {
    let title: LocalizedStringKey
    let value: Text
    var isLoading = false
    var indicator = "chevron.right"

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(title)
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurface)
            Spacer(minLength: 0)
            if isLoading {
                CellularAutomatonLoader.mini
            } else {
                value
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.middle)
                Image(systemName: indicator)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
            }
        }
        .settingsRowPadding()
        .contentShape(Rectangle())
    }
}

struct SettingsValueRow: View {
    let value: Text
    var indicator = "chevron.right"

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            value
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Image(systemName: indicator)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
        }
        .contentShape(Rectangle())
    }
}

struct SettingsActionButtonLabel<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            content()
        }
        .font(Theme.Fonts.labelMd)
        .settingsRowPadding()
        .frame(maxWidth: .infinity)
        .background(
            DefaultGlassEffectShape()
                .fill(Theme.Colors.primary.opacity(0.14))
        )
        .foregroundStyle(Theme.Colors.primary)
    }
}

struct SettingsErrorMessage: View {
    let message: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Colors.error)
            Text(verbatim: message)
                .font(Theme.Fonts.bodySm)
                .foregroundStyle(Theme.Colors.onSurface)
            Spacer(minLength: 0)
        }
        .alertGlassPill(in: SettingsSurfaceShape())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: message))
    }
}

struct SettingsNoticeMessage: View {
    let message: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Colors.primary)
            Text(LocalizedStringKey(message))
                .font(Theme.Fonts.bodySm)
                .foregroundStyle(Theme.Colors.onSurface)
            Spacer(minLength: 0)
        }
        .alertGlassPill(in: SettingsSurfaceShape())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey(message)))
    }
}
