import SwiftUI

struct ChatViewportLayout {
    static let responseComposerSpacing: CGFloat = 48

    var composerTop: CGFloat = 0
    var composerHeight: CGFloat = 0
    var contentFloorHeight: CGFloat = 0
    var anchorFloor: CGFloat = 0
    var anchorContentHeight: CGFloat = 0

    mutating func measureComposer(_ bounds: CGRect) -> Bool {
        let changed = abs(composerTop - bounds.minY) > 0.5
            || abs(composerHeight - bounds.height) > 0.5
        guard changed else { return false }
        composerTop = bounds.minY
        composerHeight = bounds.height
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
