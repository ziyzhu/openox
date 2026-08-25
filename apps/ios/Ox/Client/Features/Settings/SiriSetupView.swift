import SwiftUI

struct SiriSetupView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                VStack(spacing: Theme.Spacing.md) {
                    Text("Use Ox with Siri")
                        .font(Theme.Fonts.display)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .allowsTightening(true)
                        .foregroundStyle(Theme.Colors.onSurface)
                    Text("Say “Hey Siri, Ask Ox” to turn on Ox shortcuts.")
                        .font(Theme.Fonts.bodyMd)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                }
                SiriSetupGuide(accessibilityIdentifier: A11yID.SiriSetup.guide)
            }
            .frame(maxWidth: 560)
            .padding(Theme.Spacing.xxl)
        }
        .background(Theme.Colors.background)
        .navigationTitle("Siri")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SiriSetupGuide: View {
    let accessibilityIdentifier: String
    var compact = false

    var body: some View {
        SetupPromptGuide {
            SiriShortcutsCard(compact: compact)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
    }
}

struct SetupPromptGuide<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            content

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
    }
}

private struct SiriShortcutsCard: View {
    let compact: Bool

    private var visibleShortcuts: [String] { [
        L10n.string("Ask Ox"),
        L10n.string("Continue Chat"),
        L10n.string("Ask About Input")
    ] }

    var body: some View {
        VStack(spacing: 0) {
            Text("Turn on “Ox” shortcuts with Siri?")
                .font(Theme.Fonts.title)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(Theme.Colors.onSurface)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(compact ? Theme.Spacing.md : Theme.Spacing.lg)

            Divider()
                .overlay(Theme.Colors.onSurfaceMuted.dynamic.opacity(0.25))

            HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                Image("OxIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: compact ? 56 : 64, height: compact ? 56 : 64)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(Array(visibleShortcuts.enumerated()), id: \.offset) { _, shortcut in
                        Text(verbatim: shortcut)
                            .font(Theme.Fonts.title)
                            .foregroundStyle(Theme.Colors.onSurface)
                    }
                    Text(verbatim: "...")
                        .font(Theme.Fonts.title)
                        .foregroundStyle(Theme.Colors.onSurface)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(compact ? Theme.Spacing.md : Theme.Spacing.lg)

            HStack(spacing: Theme.Spacing.md) {
                SetupPromptControl(title: "Cancel", isPrimary: false, compact: compact)
                SetupPromptControl(title: "Turn On", isPrimary: true, compact: compact)
            }
            .padding(compact ? Theme.Spacing.sm : Theme.Spacing.md)
        }
        .background {
            Color.clear.glassEffect(
                .regular.tint(Theme.Colors.surface.dynamic),
                in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
            )
        }
        .accessibilityElement(children: .combine)
    }
}

struct SetupPromptControl: View {
    let title: LocalizedStringKey
    let isPrimary: Bool
    let compact: Bool

    var body: some View {
        Text(title)
            .font(Theme.Fonts.title)
            .foregroundStyle(foregroundStyle)
            .frame(maxWidth: .infinity)
            .frame(minHeight: compact ? 44 : 52)
            .background(backgroundStyle, in: Capsule())
    }

    private var foregroundStyle: Color {
        isPrimary ? .white : Theme.Colors.onSurface.dynamic
    }

    private var backgroundStyle: Color {
        isPrimary ? Color(uiColor: .systemBlue) : Theme.Colors.surfaceSunken.dynamic
    }
}
