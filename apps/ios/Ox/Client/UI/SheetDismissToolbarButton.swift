import SwiftUI

struct SheetDismissToolbarButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .minimumTouchTarget()
        }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
    }
}
