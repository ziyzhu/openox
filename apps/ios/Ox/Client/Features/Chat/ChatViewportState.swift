import SwiftUI

struct ChatEarlierPageCoordinator {
    private enum Request {
        case idle
        case pending(UUID)
    }

    private var boundaryVisible = false
    private var request = Request.idle

    mutating func reset() {
        boundaryVisible = false
        request = .idle
    }

    mutating func setBoundaryVisible(_ visible: Bool) {
        boundaryVisible = visible
    }

    mutating func requestIfNeeded(anchor: UUID?, isUserScrolling: Bool) {
        guard boundaryVisible,
              isUserScrolling,
              case .idle = request,
              let anchor else { return }
        request = .pending(anchor)
    }

    mutating func takePendingAnchor() -> UUID? {
        guard case .pending(let anchor) = request else { return nil }
        request = .idle
        return anchor
    }

    mutating func cancel() {
        request = .idle
    }
}

struct ChatViewportLayout {
    static let responseComposerSpacing: CGFloat = 48

    var composerBounds = CGRect.zero
    var dockBounds = CGRect.zero
    var contentFloorHeight: CGFloat = 0
    var anchorFloor: CGFloat = 0
    var anchorContentHeight: CGFloat = 0

    var composerTop: CGFloat { composerBounds.minY }
    var composerHeight: CGFloat { composerBounds.height }
    var dockHeight: CGFloat { dockBounds.height }

    mutating func measureComposer(_ bounds: CGRect) -> Bool {
        let changed = abs(composerBounds.minY - bounds.minY) > 0.5
            || abs(composerBounds.height - bounds.height) > 0.5
            || abs(composerBounds.width - bounds.width) > 0.5
        guard changed else { return false }
        composerBounds = bounds
        return true
    }

    mutating func measureDock(_ bounds: CGRect) -> Bool {
        let changed = abs(dockBounds.minY - bounds.minY) > 0.5
            || abs(dockBounds.height - bounds.height) > 0.5
            || abs(dockBounds.width - bounds.width) > 0.5
        guard changed else { return false }
        dockBounds = bounds
        return true
    }

    mutating func measureViewport(_ height: CGFloat, bottomMargin: CGFloat, focused: Bool) {
        contentFloorHeight = max(0, height - bottomMargin)
        if !focused { anchorFloor = max(anchorFloor, contentFloorHeight) }
    }

    mutating func measureAnchorContent(_ height: CGFloat) {
        anchorContentHeight = height
    }

    func slack(hasAnchor: Bool) -> CGFloat {
        hasAnchor ? max(0, anchorFloor - anchorContentHeight) : 0
    }
}
