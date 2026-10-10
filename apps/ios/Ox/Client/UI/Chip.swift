import SwiftUI

struct OxChipButton: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var filled: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.labelMd)
            .foregroundStyle(filled ? Theme.Colors.onPrimary : Theme.Colors.onSurface)
            .padding(.horizontal, Theme.Spacing.md)
            .chipSurface(
                (filled ? Theme.Colors.primary : Theme.Colors.chipOnBackground)
                    .opacity(configuration.isPressed ? 0.7 : 1.0)
            )
            .minimumTouchTarget()
            .animation(nil, value: filled)
            .animation(reduceMotion ? nil : Theme.Animation.press, value: configuration.isPressed)
    }
}

struct Chip<Content: View>: View {
    var fill = Theme.Colors.surfaceSunken
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) { content() }
            .padding(.horizontal, Theme.Spacing.md)
            .chipSurface(fill)
    }
}

struct ChipFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let availableWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0
        var contentHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextWidth = rowWidth == 0 ? size.width : rowWidth + spacing + size.width
            if rowWidth > 0, nextWidth > availableWidth {
                contentWidth = max(contentWidth, rowWidth)
                contentHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth = nextWidth
                rowHeight = max(rowHeight, size.height)
            }
        }

        contentWidth = max(contentWidth, rowWidth)
        contentHeight += rowHeight
        return CGSize(width: proposal.width ?? contentWidth, height: contentHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
