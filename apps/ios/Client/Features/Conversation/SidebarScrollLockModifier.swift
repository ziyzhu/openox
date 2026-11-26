import SwiftUI

struct SidebarScrollLockModifier: ViewModifier {
    @Environment(\.sidebarInteraction) private var sidebarInteraction

    func body(content: Content) -> some View {
        content.scrollDisabled(sidebarInteraction.dragActive)
    }
}
