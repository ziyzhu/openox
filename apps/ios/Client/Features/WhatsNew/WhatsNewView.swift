import SwiftUI

struct WhatsNewView: View {
    let releases: [WhatsNewRelease]
    let onDone: () -> Void

    @State private var selection: String

    init(releases: [WhatsNewRelease], onDone: @escaping () -> Void) {
        self.releases = releases
        self.onDone = onDone
        _selection = State(initialValue: releases.first?.id ?? "")
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(releases) { release in
                WhatsNewPage(release: release, isActive: selection == release.id, onDone: onDone)
                    .tag(release.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .overlay(alignment: .top) {
            if releases.count > 1 {
                HStack(spacing: 6) {
                    ForEach(releases) { release in
                        Circle()
                            .fill(Theme.Colors.primary.opacity(release.id == selection ? 1 : 0.25))
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(Theme.Spacing.sm)
                .background(Theme.Colors.surface, in: Capsule())
                .padding(.top, Theme.Spacing.xs)
                .accessibilityHidden(true)
            }
        }
        .background(Theme.Colors.surface, ignoresSafeAreaEdges: .all)
        .presentationDragIndicator(.hidden)
        .environment(\.locale, AppLocale.shared.locale)
        .onAppear {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
}

private struct WhatsNewPage: View {
    let release: WhatsNewRelease
    let isActive: Bool
    let onDone: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    OnboardingCellularField(isActive: isActive)
                        .frame(height: dynamicTypeSize.isAccessibilitySize ? 80 : 112)
                        .padding(.top, Theme.Spacing.lg)
                        .accessibilityHidden(true)

                    Text("What's New")
                        .font(Theme.Fonts.display)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.Colors.onSurface)
                        .padding(.top, Theme.Spacing.lg)

                    Text("Version \(release.version)")
                        .font(Theme.Fonts.bodySm)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                        .padding(.top, Theme.Spacing.xs)

                    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                        ForEach(Array(release.items.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                                Text(verbatim: "\(index + 1).")
                                    .font(Theme.Fonts.bodyMd.monospacedDigit())
                                    .foregroundStyle(Theme.Colors.primary)
                                Text(LocalizedStringKey(item))
                                    .font(Theme.Fonts.bodyMd)
                                    .foregroundStyle(Theme.Colors.onSurface)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.top, Theme.Spacing.xl)
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, Theme.Spacing.xxl)
                .padding(.vertical, Theme.Spacing.lg)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)

            Button {
                Log.ui.info("WhatsNew.done version=\(release.version)")
                onDone()
            } label: {
                Text("Got it")
            }
            .buttonStyle(OnboardingCTAButton())
            .accessibilityIdentifier(A11yID.WhatsNew.done(release.version))
            .frame(maxWidth: 560)
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.vertical, Theme.Spacing.lg)
        }
        .accessibilityIdentifier(A11yID.WhatsNew.page(release.version))
    }
}

struct WhatsNewListView: View {
    @State private var selected: WhatsNewRelease?

    var body: some View {
        ScrollView {
            SettingsSection(layout: .group) {
                VStack(spacing: 0) {
                    ForEach(Array(WhatsNew.shipped.enumerated()), id: \.element.id) { index, release in
                        if index > 0 {
                            Divider().settingsContentInset()
                        }
                        Button { selected = release } label: {
                            WhatsNewReleaseRow(release: release)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(A11yID.WhatsNew.release(release.version))
                    }
                }
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .settingsPagePadding()
        }
        .scrollIndicators(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle("What's New")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selected) { release in
            WhatsNewView(releases: [release]) { selected = nil }
        }
    }
}

private struct WhatsNewReleaseRow: View {
    let release: WhatsNewRelease

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Version \(release.version)")
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                if let first = release.items.first {
                    Text(LocalizedStringKey(first))
                        .font(Theme.Fonts.bodySm)
                        .foregroundStyle(Theme.Colors.conversationSecondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(Theme.Icons.xs)
                .foregroundStyle(Theme.Colors.conversationSecondary)
        }
        .settingsRowPadding()
        .contentShape(Rectangle())
    }
}
