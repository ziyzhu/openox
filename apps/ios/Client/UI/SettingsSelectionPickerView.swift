import SwiftUI

struct SettingsSelectionOption<Value: Hashable>: Identifiable {
    let id: String
    let value: Value
    let title: String
    var systemImage: String? = nil
    var faviconDomain: String? = nil
    var faviconURL: URL? = nil
    var subtitle: String? = nil
    let accessibilityIdentifier: String
    var children: [SettingsSelectionOption<Value>] = []
}

struct SettingsSelectionPickerView<Value: Hashable>: View {
    let title: LocalizedStringKey
    let options: [SettingsSelectionOption<Value>]
    @Binding var selection: Value
    var onSelect: ((Value) -> Void)? = nil
    var searchAccessibilityIdentifier: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        if let searchAccessibilityIdentifier {
            page.oxSearchable(text: $query, accessibilityIdentifier: searchAccessibilityIdentifier)
        } else {
            page
        }
    }

    private var page: some View {
        ScrollView {
            if displayedOptions.isEmpty && !options.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                optionGroup(displayedOptions)
                    .settingsPagePadding()
            }
        }
        .scrollIndicators(.hidden)
        .background(Theme.Colors.background, ignoresSafeAreaEdges: .all)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var displayedOptions: [SettingsSelectionOption<Value>] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return options }
        return options.filter {
            $0.title.localizedCaseInsensitiveContains(needle) || $0.id.localizedCaseInsensitiveContains(needle)
        }
    }

    private func optionGroup(_ options: [SettingsSelectionOption<Value>]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                if index > 0 { Divider().settingsContentInset() }
                optionRow(option)
            }
        }
        .settingsSurface()
    }

    private func select(_ value: Value) {
        if let onSelect {
            onSelect(value)
        } else {
            selection = value
            dismiss()
        }
    }

    @ViewBuilder
    private func optionRow(_ option: SettingsSelectionOption<Value>) -> some View {
        if option.children.isEmpty {
            Button { select(option.value) } label: {
                optionLabel(option)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(option.accessibilityIdentifier)
            .accessibilityValue(selection == option.value ? L10n.string("Selected") : "")
        } else {
            NavigationLink {
                SettingsSelectionPickerView(
                    title: LocalizedStringKey(option.title),
                    options: option.children,
                    selection: $selection,
                    onSelect: select
                )
            } label: {
                optionLabel(option)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(option.accessibilityIdentifier)
        }
    }

    private func optionLabel(_ option: SettingsSelectionOption<Value>) -> some View {
        HStack(spacing: SettingsLayout.horizontalInset) {
            if let faviconDomain = option.faviconDomain {
                DomainFavicon(domain: faviconDomain, size: 24, overrideURL: option.faviconURL)
            }
            if let systemImage = option.systemImage {
                Image(systemName: systemImage)
                    .font(.system(.body, weight: .medium))
                    .foregroundStyle(Theme.Colors.primary)
                    .frame(width: 24, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: option.title)
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                if let subtitle = option.subtitle {
                    Text(LocalizedStringKey(subtitle))
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.conversationSecondary)
                }
            }
            Spacer(minLength: 0)
            if !option.children.isEmpty {
                Image(systemName: "chevron.right")
                    .font(Theme.Icons.xs)
                    .foregroundStyle(Theme.Colors.conversationSecondary)
            } else if selection == option.value {
                Image(systemName: "checkmark")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.Colors.primary)
            }
        }
        .padding(.horizontal, SettingsLayout.horizontalInset)
        .padding(.vertical, SettingsLayout.rowVerticalInset)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
