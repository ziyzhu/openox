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

struct ChatKeyboardOverlapGuard {
    private var composerFrame = CGRect.null
    private var keyboardFrame = CGRect.null
    private var toleratedOverlap: CGFloat = 0
    private(set) var correction: CGFloat = 0

    mutating func measureComposer(_ frame: CGRect, toleratedOverlap: CGFloat) -> Bool {
        composerFrame = frame
        self.toleratedOverlap = toleratedOverlap
        return reconcile()
    }

    mutating func keyboardChanged(to frame: CGRect?) -> Bool {
        keyboardFrame = frame ?? .null
        return reconcile()
    }

    mutating func reset() {
        composerFrame = .null
        keyboardFrame = .null
        correction = 0
    }

    private mutating func reconcile() -> Bool {
        guard !composerFrame.isNull, !keyboardFrame.isNull else {
            return setCorrection(0)
        }
        let intersectsHorizontally = composerFrame.maxX > keyboardFrame.minX
            && composerFrame.minX < keyboardFrame.maxX
        let overlap = intersectsHorizontally
            ? max(0, composerFrame.maxY - keyboardFrame.minY)
            : 0
        let next = overlap > toleratedOverlap + 0.5 ? overlap : 0
        return setCorrection(next)
    }

    private mutating func setCorrection(_ value: CGFloat) -> Bool {
        guard abs(correction - value) > 0.5 else { return false }
        correction = value
        return true
    }
}
