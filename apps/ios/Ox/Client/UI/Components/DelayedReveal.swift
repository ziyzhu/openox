import SwiftUI

private struct DelayedReveal<ID: Equatable>: ViewModifier {
    let delay: Duration
    let id: ID

    @State private var revealedID: ID?

    private var revealed: Bool { revealedID == id }

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .accessibilityHidden(!revealed)
            .task(id: id) {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                withAnimation(Theme.Animation.standard) { revealedID = id }
            }
    }
}

extension View {
    func revealed<ID: Equatable>(after delay: Duration, id: ID) -> some View {
        modifier(DelayedReveal(delay: delay, id: id))
    }

    func revealed(after delay: Duration) -> some View {
        revealed(after: delay, id: 0)
    }
}
