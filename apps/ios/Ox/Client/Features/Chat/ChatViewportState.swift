import SwiftUI

struct ChatViewportLayout {
    static let responseComposerSpacing: CGFloat = 48

    var composerHeight: CGFloat = 0
    var contentFloorHeight: CGFloat = 0
    var anchorFloor: CGFloat = 0
    var anchorContentHeight: CGFloat = 0

    mutating func measureComposerHeight(_ height: CGFloat) -> Bool {
        guard abs(composerHeight - height) > 0.5 else { return false }
        composerHeight = height
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
