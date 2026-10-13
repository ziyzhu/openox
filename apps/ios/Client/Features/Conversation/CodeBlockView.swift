import SwiftUI

struct CodeBlockHeader<Controls: View>: View {
    let language: String?
    var code: String? = nil
    var isStreaming = false
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.sm) {
            Text(DiffDocument.supports(language) ? "Changes" : language ?? "Text")
                .font(Theme.Fonts.caption.weight(.medium))
                .foregroundStyle(Theme.Colors.onSurface)
            Spacer(minLength: 0)
            if DiffDocument.supports(language), let code, !isStreaming {
                let document = DiffDocument(code)
                if document.files.isEmpty {
                    DiffChangeCounts(additions: document.additions, deletions: document.deletions)
                } else {
                    Text(document.files.count == 1 ? "1 file" : "\(document.files.count) files")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(.secondary)
                }
            }
            controls()
        }
        .frame(minHeight: 22)
    }
}

struct CodeBlockSurface<Header: View, Content: View>: View {
    var scrollsHorizontally = true
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            header()
                .padding(.horizontal, Theme.Spacing.lg)
            if scrollsHorizontally {
                ScrollView(.horizontal, showsIndicators: false) {
                    content()
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .excludesCompactPageSwitch()
                .defaultScrollAnchor(nil, for: .sizeChanges)
            } else {
                content()
            }
        }
        .padding(.vertical, Theme.Spacing.lg)
        .background(
            Theme.Colors.conversationCodeSurface,
            in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                .strokeBorder(Theme.Colors.conversationCodeBorder, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

struct CodeBlockView: View {
    let code: String
    let accessibilityIdentifier: String
    var language: String? = nil
    var title: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if let title {
                Text(title)
                    .font(Theme.Fonts.captionMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .padding(.horizontal, Theme.Spacing.lg)
            }
            CodeBlockSurface(scrollsHorizontally: !DiffDocument.supports(language)) {
                CodeBlockHeader(language: language, code: code) { EmptyView() }
            } content: {
                if DiffDocument.supports(language) {
                    DiffCodeBlockBody(code: code, accessibilityIdentifier: accessibilityIdentifier)
                } else {
                    SelectableText(code: code, language: language)
                }
            }
        }
    }
}
