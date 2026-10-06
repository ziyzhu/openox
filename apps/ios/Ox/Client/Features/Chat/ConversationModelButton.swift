import SwiftUI

struct ConversationModelButton: View {
    let title: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(Theme.Fonts.labelMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.down")
                    .font(Theme.Icons.xs)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
            }
            .padding(.horizontal, 14)
            .frame(height: size)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityLabel("Model: \(title)")
        .accessibilityIdentifier(A11yID.Chat.modelPicker)
    }
}
