import SwiftUI

enum ConversationSendHandoff: Equatable {
    static let rise = Spring(duration: 0.25, bounce: 0)
    static let reveal = Animation.linear(duration: 0.12)
    static let revealStartOpacity = 0.2

    struct Capture: Equatable {
        let submissionID: UUID
        let origin: CGPoint
        let readingHistory: Bool
        var frame = CGRect.null
    }

    case idle
    case waitingForAnchor(Capture)
    case positioned(Capture, offset: CGFloat, anchorTop: CGFloat)
    case animating(UUID)

    mutating func measure(frame: CGRect, submissionID: UUID) {
        guard case .waitingForAnchor(var capture) = self,
              capture.submissionID == submissionID else { return }
        capture.frame = frame
        self = .waitingForAnchor(capture)
    }
}
