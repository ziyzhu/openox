import SwiftUI

struct CodeBlockHeader<Controls: View>: View {
    let language: String?
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.sm) {
            Text(language ?? "Text")
                .font(Theme.Fonts.caption.weight(.medium))
                .foregroundStyle(Theme.Colors.onSurface)
            Spacer(minLength: 0)
            controls()
        }
        .frame(minHeight: 22)
    }
}

struct CodeBlockSurface<Header: View, Content: View>: View {
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            header()
                .padding(.horizontal, Theme.Spacing.lg)
            ScrollView(.horizontal, showsIndicators: false) {
                content()
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .excludesCompactPageSwitch()
            .defaultScrollAnchor(nil, for: .sizeChanges)
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
            CodeBlockSurface {
                CodeBlockHeader(language: language) { EmptyView() }
            } content: {
                SelectableText(code: code, language: language)
            }
        }
    }
}
