import SwiftUI

struct CodeBlockView: View {
    let code: String
    var language: String? = nil
    var title: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if let title {
                Text(title)
                    .font(Theme.Fonts.captionMd)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Spacing.sm)
            }
            VStack(alignment: .leading, spacing: 0) {
                if let language {
                    Text(language)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.top, Theme.Spacing.sm)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    SelectableText(code: code, language: language)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(Theme.Spacing.md)
                }
                .excludesCompactPageSwitch()
            }
            .background(Theme.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
    }
}
