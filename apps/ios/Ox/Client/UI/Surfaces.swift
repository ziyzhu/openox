import SwiftUI

extension View {
    func chatCardOutline(cornerRadius: CGFloat = Theme.Radius.lg) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Theme.Colors.onSurfaceMuted.opacity(0.18), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    func chipSurface<S: ShapeStyle>(_ fill: S) -> some View {
        frame(height: Theme.Size.chipHeight)
            .background(fill, in: Capsule(style: .continuous))
    }

    func contextMenuPreviewShape() -> some View {
        contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
    }

    func pressedSurface(_ isPressed: Bool) -> some View {
        opacity(isPressed ? 0.7 : 1.0)
    }

    func minimumTouchTarget(alignment: Alignment = .center) -> some View {
        frame(
            minWidth: Theme.Size.minimumTouchTarget,
            minHeight: Theme.Size.minimumTouchTarget,
            alignment: alignment
        )
        .contentShape(Rectangle())
    }
}

struct OxPressedSurfaceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .pressedSurface(configuration.isPressed)
    }
}
