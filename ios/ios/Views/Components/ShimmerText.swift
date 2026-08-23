import SwiftUI

struct ShimmerText: View {
    let text: AttributedString
    var lineLimit = 3

    nonisolated private static let period = 1.2
    nonisolated private static let band = 0.35

    var body: some View {
        let shimmerColor = Theme.Colors.onSurfaceMuted.dynamic
        Text(text)
            .font(Theme.Fonts.bodyMd)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .contentTransition(.opacity)
            .keyframeAnimator(initialValue: -Self.band, repeating: true) { content, center in
                content.foregroundStyle(Self.gradient(at: center, base: shimmerColor))
            } keyframes: { _ in
                LinearKeyframe(1 + Self.band, duration: Self.period)
            }
    }

    nonisolated private static func gradient(at center: Double, base: Color) -> LinearGradient {
        let highlight = base.opacity(0.3)
        func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
        return LinearGradient(
            gradient: Gradient(stops: [
                .init(color: base, location: 0),
                .init(color: base, location: clamp(center - band)),
                .init(color: highlight, location: clamp(center)),
                .init(color: base, location: clamp(center + band)),
                .init(color: base, location: 1),
            ]),
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
