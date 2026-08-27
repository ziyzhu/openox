import SwiftUI

@MainActor
@Observable
final class ChatViewportController {
    enum Target: Equatable {
        case turnTop(UUID)
        case bottom

        var label: String {
            switch self {
            case .turnTop(let id): "turnTop(\(id.uuidString.prefix(8)))"
            case .bottom: "bottom"
            }
        }
    }

    struct Frame: Equatable {
        let visualTop: CGFloat
        let content: CGFloat
        let container: CGFloat
        let insetTop: CGFloat
        let insetBottom: CGFloat
        let distanceFromEnd: CGFloat

        init(_ geometry: ScrollGeometry) {
            visualTop = geometry.contentOffset.y + geometry.contentInsets.top
            content = geometry.contentSize.height
            container = geometry.containerSize.height
            insetTop = geometry.contentInsets.top
            insetBottom = geometry.contentInsets.bottom
            distanceFromEnd = geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY
        }

        var summary: String {
            "top=\(Int(visualTop)) content=\(Int(content)) container=\(Int(container)) insets=\(Int(insetTop))/\(Int(insetBottom)) fromEnd=\(Int(distanceFromEnd))"
        }

        var jumpDistance: CGFloat {
            max(0, distanceFromEnd - insetBottom)
        }
    }

    private enum Motion: Equatable {
        case stationary
        case user(ScrollPhase)
        case programmatic(Target)

        var label: String {
            switch self {
            case .stationary: "stationary"
            case .user(let phase): "user(\(String(describing: phase)))"
            case .programmatic(let target): "programmatic(\(target.label))"
            }
        }
    }

    private static let jumpThreshold: CGFloat = 32

    private(set) var showsJumpButton = false
    private(set) var visibleBlockID: UUID?

    var isUserScrolling: Bool {
        if case .user = motion { return true }
        return false
    }

    @ObservationIgnored private var chatID = ""
    @ObservationIgnored private var frame: Frame?
    @ObservationIgnored private var motion = Motion.stationary
    @ObservationIgnored private var pendingOpenCompletion: (() -> Void)?
    @ObservationIgnored private var visibleBlockIDs: Set<UUID> = []
    @ObservationIgnored private var keyboardClearanceTarget: UUID?

    func openAtBottom(chatID: String, onSettled: @escaping () -> Void) {
        self.chatID = chatID
        frame = nil
        pendingOpenCompletion = onSettled
        showsJumpButton = false
        visibleBlockID = nil
        visibleBlockIDs = []
        keyboardClearanceTarget = nil
        move(to: .bottom)
        Log.ui.info("Transcript.open chat=\(chatID) target=bottom")
    }

    func rideToTurn(_ id: UUID, animated: Bool, scroll: () -> Void) {
        let target = Target.turnTop(id)
        move(to: target)
        Log.ui.info("Transcript.anchor chat=\(chatID) target=\(target.label) anchor=top animated=\(animated)")
        guard animated else {
            scroll()
            return
        }
        withAnimation(Theme.Animation.ride) {
            scroll()
        }
    }

    func rideToBottom(scroll: () -> Void) {
        Log.ui.info("Transcript.anchor chat=\(chatID) target=bottom")
        guard frame?.jumpDistance ?? .infinity > 1 else {
            motion = .stationary
            scroll()
            return
        }
        move(to: .bottom)
        withAnimation(.easeOut(duration: Theme.Animation.drop)) {
            scroll()
        }
    }

    func preservePageAnchor(_ id: UUID, scroll: () -> Void) {
        scroll()
        Log.ui.info("Transcript.pageAnchor chat=\(chatID) block=\(id)")
    }

    func visibleBlocksChanged(_ ids: [UUID]) -> UUID? {
        visibleBlockID = ids.first
        visibleBlockIDs = Set(ids)
        guard let target = keyboardClearanceTarget,
              !visibleBlockIDs.contains(target) else { return nil }
        keyboardClearanceTarget = nil
        return target
    }

    func focusChanged(_ focused: Bool, lastAgentBlockID: UUID?, isBusy: Bool) {
        guard focused, !isBusy,
              let lastAgentBlockID,
              visibleBlockIDs.contains(lastAgentBlockID) else {
            keyboardClearanceTarget = nil
            return
        }
        keyboardClearanceTarget = lastAgentBlockID
    }

    func revealAboveKeyboard(_ id: UUID, scroll: () -> Void) {
        scroll()
        Log.ui.info("Transcript.keyboardClearance chat=\(chatID) block=\(id)")
    }

    func busyChanged(_ busy: Bool) {
        if busy { keyboardClearanceTarget = nil }
    }

    func phaseChanged(from old: ScrollPhase, to new: ScrollPhase) {
        if new.isUserDriven {
            keyboardClearanceTarget = nil
            motion = .user(new)
        } else if new == .idle {
            motion = .stationary
        }
        Log.ui.info("Transcript.phase chat=\(chatID) \(String(describing: old)) -> \(String(describing: new)) owner=\(motion.label)")
    }

    func geometryChanged(_ new: Frame) {
        frame = new
        updateJumpButton(new)
        if case .programmatic(.bottom) = motion, new.distanceFromEnd <= 1 {
            motion = .stationary
            let completion = pendingOpenCompletion
            pendingOpenCompletion = nil
            completion?()
            Log.ui.info("Transcript.openSettled chat=\(chatID) \(new.summary)")
        }
    }

    private func move(to target: Target) {
        motion = .programmatic(target)
    }

    private func updateJumpButton(_ frame: Frame) {
        let shows = frame.jumpDistance > Self.jumpThreshold
        guard shows != showsJumpButton else { return }
        showsJumpButton = shows
        Log.ui.info("Transcript.jumpButton chat=\(chatID) shows=\(shows) fromEnd=\(Int(frame.distanceFromEnd)) inset=\(Int(frame.insetBottom))")
    }
}

private extension ScrollPhase {
    var isUserDriven: Bool {
        switch self {
        case .tracking, .interacting, .decelerating: true
        case .idle, .animating: false
        }
    }
}
