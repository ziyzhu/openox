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

    struct ComposerReflowRequest: Equatable, Identifiable {
        let id = UUID()
        let responseID: UUID
        let targetY: CGFloat
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

    private struct ResponseComposerAnchor: Equatable {
        let responseID: UUID
    }

    private enum ComposerReflow: Equatable {
        case inactive
        case preservingScrollPosition
        case preservingSpacing(ResponseComposerAnchor)
        case requested(ResponseComposerAnchor, ComposerReflowRequest)
        case settling(ResponseComposerAnchor)

        var request: ComposerReflowRequest? {
            guard case .requested(_, let request) = self else { return nil }
            return request
        }
    }

    private static let jumpThreshold: CGFloat = 32
    private static let spacingTolerance: CGFloat = 0.5

    private(set) var showsJumpButton = false
    private(set) var visibleBlockID: UUID?
    private var composerReflow = ComposerReflow.inactive

    var composerReflowRequest: ComposerReflowRequest? { composerReflow.request }

    var isUserScrolling: Bool {
        if case .user = motion { return true }
        return false
    }

    @ObservationIgnored private var chatID = ""
    @ObservationIgnored private var frame: Frame?
    @ObservationIgnored private var motion = Motion.stationary
    @ObservationIgnored private var pendingOpenCompletion: (() -> Void)?
    @ObservationIgnored private var composerTop: CGFloat?
    @ObservationIgnored private var restingComposerTop: CGFloat?
    @ObservationIgnored private var responseBottoms: [UUID: CGFloat] = [:]

    func openAtBottom(chatID: String, onSettled: @escaping () -> Void) {
        self.chatID = chatID
        frame = nil
        pendingOpenCompletion = onSettled
        showsJumpButton = false
        visibleBlockID = nil
        composerReflow = .inactive
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

    func visibleBlocksChanged(_ ids: [UUID]) {
        visibleBlockID = ids.first
    }

    func focusChanged(_ focused: Bool, lastResponseFooterID: UUID?, isBusy: Bool) {
        guard focused else {
            composerReflow = .inactive
            return
        }
        guard !isBusy,
              let lastResponseFooterID,
              let responseBottom = responseBottoms[lastResponseFooterID],
              let referenceComposerTop = restingComposerTop ?? composerTop else {
            composerReflow = .preservingScrollPosition
            return
        }
        let gap = referenceComposerTop - responseBottom
        guard gap >= -Self.spacingTolerance else {
            composerReflow = .preservingScrollPosition
            Log.ui.info("Transcript.composerReflow chat=\(chatID) mode=scrollPosition gap=\(Int(gap))")
            return
        }
        let anchor = ResponseComposerAnchor(responseID: lastResponseFooterID)
        composerReflow = .preservingSpacing(anchor)
        Log.ui.info("Transcript.composerReflow chat=\(chatID) mode=responseSpacing block=\(lastResponseFooterID) gap=\(Int(gap)) target=\(Int(ChatViewportLayout.responseComposerSpacing))")
        updateComposerReflow()
    }

    func applyComposerReflow(_ request: ComposerReflowRequest, scroll: () -> Void) {
        guard case .requested(let anchor, let pendingRequest) = composerReflow,
              pendingRequest.id == request.id else { return }
        withAnimation(.easeOut(duration: Theme.Animation.standard)) {
            scroll()
        }
        composerReflow = .settling(anchor)
        Log.ui.info("Transcript.composerReflow chat=\(chatID) applied=\(request.id) block=\(request.responseID) targetY=\(Int(request.targetY))")
    }

    func composerBoundsChanged(_ bounds: CGRect, focused: Bool) {
        composerTop = bounds.minY
        if !focused { restingComposerTop = bounds.minY }
        updateComposerReflow()
    }

    func responseFooterBoundsChanged(id: UUID, bounds: CGRect) {
        responseBottoms[id] = bounds.maxY
        updateComposerReflow()
    }

    func busyChanged(_ busy: Bool) {
        if busy { composerReflow = .inactive }
    }

    func phaseChanged(from old: ScrollPhase, to new: ScrollPhase) {
        if new.isUserDriven {
            composerReflow = .preservingScrollPosition
            motion = .user(new)
        } else if new == .idle {
            motion = .stationary
            if case .settling(let anchor) = composerReflow {
                composerReflow = .preservingSpacing(anchor)
                updateComposerReflow()
            }
        }
        Log.ui.info("Transcript.phase chat=\(chatID) \(String(describing: old)) -> \(String(describing: new)) owner=\(motion.label)")
    }

    func geometryChanged(_ new: Frame) {
        frame = new
        updateJumpButton(new)
        updateComposerReflow()
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

    private func updateComposerReflow() {
        guard case .preservingSpacing(let anchor) = composerReflow,
              let composerTop,
              let responseBottom = responseBottoms[anchor.responseID],
              let frame else { return }
        let gap = composerTop - responseBottom
        let correction = ChatViewportLayout.responseComposerSpacing - gap
        guard correction > Self.spacingTolerance else { return }
        let request = ComposerReflowRequest(
            responseID: anchor.responseID,
            targetY: frame.visualTop + correction
        )
        composerReflow = .requested(anchor, request)
        Log.ui.info("Transcript.composerReflow chat=\(chatID) request=\(request.id) block=\(anchor.responseID) gap=\(Int(gap)) correction=\(Int(correction))")
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
