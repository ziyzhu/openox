import SwiftUI

enum ConversationSendHandoff: Equatable {
    struct Capture: Equatable {
        let submissionID: UUID
        let origin: CGPoint
        var frame = CGRect.null
        var bubble: SendFlight.Bubble?
    }

    case idle
    case waitingForAnchor(Capture)
    case positioned(Capture, offset: CGFloat, anchorTop: CGFloat)
    case animating(UUID, bubble: SendFlight.Bubble?, path: SendFlight.Path?)

    var origin: CGPoint? {
        switch self {
        case .waitingForAnchor(let capture), .positioned(let capture, _, _): capture.origin
        case .idle, .animating: nil
        }
    }

    var bubble: SendFlight.Bubble? {
        switch self {
        case .waitingForAnchor(let capture), .positioned(let capture, _, _): capture.bubble
        case .animating(_, let bubble, _): bubble
        case .idle: nil
        }
    }

    var path: SendFlight.Path? {
        guard case .animating(_, _, let path) = self else { return nil }
        return path
    }

    mutating func measure(frame: CGRect, submissionID: UUID) {
        guard case .waitingForAnchor(var capture) = self,
              capture.submissionID == submissionID else { return }
        capture.frame = frame
        self = .waitingForAnchor(capture)
    }

    mutating func capture(bubble: SendFlight.Bubble) {
        switch self {
        case .waitingForAnchor(var capture):
            capture.bubble = bubble
            self = .waitingForAnchor(capture)
        case .positioned(var capture, let offset, let anchorTop):
            capture.bubble = bubble
            self = .positioned(capture, offset: offset, anchorTop: anchorTop)
        case .idle, .animating:
            break
        }
    }
}
