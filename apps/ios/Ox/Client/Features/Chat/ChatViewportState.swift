import SwiftUI

struct ChatViewportLayout {
    private struct ComposerMetrics {
        var top: CGFloat = 0
        var height: CGFloat = 0
    }

    private struct AnchorMetrics {
        var contentFloorHeight: CGFloat = 0
        var unfocusedFloorHighWaterMark: CGFloat = 0
        var contentHeight: CGFloat = 0

        var minimumHeight: CGFloat {
            max(unfocusedFloorHighWaterMark, contentFloorHeight)
        }

        func slack(hasAnchor: Bool) -> CGFloat {
            hasAnchor ? max(0, unfocusedFloorHighWaterMark - contentHeight) : 0
        }
    }

    static let responseComposerSpacing: CGFloat = 48
    private static let measurementTolerance: CGFloat = 0.5

    private var composer = ComposerMetrics()
    private var anchor = AnchorMetrics()

    var composerTop: CGFloat { composer.top }
    var composerHeight: CGFloat { composer.height }
    var contentFloorHeight: CGFloat { anchor.contentFloorHeight }
    var anchoredContentMinimumHeight: CGFloat { anchor.minimumHeight }

    mutating func measureComposer(_ bounds: CGRect) -> Bool {
        let measured = ComposerMetrics(top: bounds.minY, height: bounds.height)
        let changed = abs(composer.top - measured.top) > Self.measurementTolerance
            || abs(composer.height - measured.height) > Self.measurementTolerance
        guard changed else { return false }
        composer = measured
        return true
    }

    mutating func measureViewport(_ height: CGFloat, bottomMargin: CGFloat, focused: Bool) {
        anchor.contentFloorHeight = max(0, height - bottomMargin)
        if !focused {
            anchor.unfocusedFloorHighWaterMark = max(
                anchor.unfocusedFloorHighWaterMark,
                anchor.contentFloorHeight
            )
        }
    }

    mutating func measureAnchorContent(_ height: CGFloat) {
        anchor.contentHeight = height
    }

    func slack(hasAnchor: Bool) -> CGFloat {
        anchor.slack(hasAnchor: hasAnchor)
    }
}
