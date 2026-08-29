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
        let id: UUID
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

    private struct ComposerReflowWatch: Equatable {
        let responseID: UUID
        var composerTop: CGFloat
        var gap: CGFloat
    }

    private struct ComposerReflowSession: Equatable {
        let id = UUID()
        let responseID: UUID
        let initialGap: CGFloat
    }

    private enum ComposerReflow: Equatable {
        case inactive
        case watching(ComposerReflowWatch)
        case requested(ComposerReflowSession, ComposerReflowRequest)
        case settling(ComposerReflowSession)

        var request: ComposerReflowRequest? {
            guard case .requested(_, let request) = self else { return nil }
            return request
        }
    }

    private static let jumpThreshold: CGFloat = 32
    private static let spacingTolerance: CGFloat = 0.5
    private static let minimumAnchoredGap: CGFloat = -10

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
    @ObservationIgnored private var reflowResponseID: UUID?
    @ObservationIgnored private var inputFocused = false
    @ObservationIgnored private var isBusy = false

    func openAtBottom(chatID: String, onSettled: @escaping () -> Void) {
        self.chatID = chatID
        frame = nil
        pendingOpenCompletion = onSettled
        showsJumpButton = false
        visibleBlockID = nil
        composerReflow = .inactive
        reflowResponseID = nil
        inputFocused = false
        isBusy = false
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
        inputFocused = focused
        self.isBusy = isBusy
        reflowResponseID = lastResponseFooterID
        guard focused else {
            composerReflow = .inactive
            return
        }
        beginWatching(
            composerTop: restingComposerTop ?? composerTop,
            reason: "focus"
        )
    }

    func applyComposerReflow(_ request: ComposerReflowRequest, scroll: () -> Void) {
        guard case .requested(let session, let pendingRequest) = composerReflow,
              pendingRequest.id == request.id else { return }
        withAnimation(.easeOut(duration: Theme.Animation.standard)) {
            scroll()
        }
        composerReflow = .settling(session)
        Log.ui.info("Transcript.composerReflow chat=\(chatID) applied=\(request.id) block=\(request.responseID) targetY=\(Int(request.targetY))")
    }

    func composerBoundsChanged(_ bounds: CGRect, focused: Bool) {
        composerTop = bounds.minY
        inputFocused = focused
        guard focused else {
            restingComposerTop = bounds.minY
            composerReflow = .inactive
            return
        }
        prepareComposerReflow()
    }

    func responseFooterBoundsChanged(id: UUID, bounds: CGRect) {
        responseBottoms[id] = bounds.maxY
    }

    func busyChanged(_ busy: Bool) {
        isBusy = busy
        if busy { composerReflow = .inactive }
    }

    func phaseChanged(from old: ScrollPhase, to new: ScrollPhase) {
        if new.isUserDriven {
            composerReflow = .inactive
            motion = .user(new)
        } else if new == .idle {
            motion = .stationary
            if case .settling(let session) = composerReflow {
                Log.ui.info("Transcript.composerReflow chat=\(chatID) settled=\(session.id) block=\(session.responseID)")
            }
            beginWatching(composerTop: composerTop, reason: "scrollSettled")
        }
        Log.ui.info("Transcript.phase chat=\(chatID) \(String(describing: old)) -> \(String(describing: new)) owner=\(motion.label)")
    }

    func geometryChanged(_ new: Frame) {
        frame = new
        updateJumpButton(new)
        prepareComposerReflow()
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

    private func beginWatching(composerTop: CGFloat?, reason: String) {
        guard inputFocused,
              !isBusy,
              let responseID = reflowResponseID,
              let responseBottom = responseBottoms[responseID],
              let composerTop else {
            composerReflow = .inactive
            return
        }
        let gap = composerTop - responseBottom
        guard gap >= Self.minimumAnchoredGap else {
            composerReflow = .inactive
            Log.ui.info("Transcript.composerReflow chat=\(chatID) mode=scrollPosition gap=\(Int(gap)) reason=\(reason)")
            return
        }
        composerReflow = .watching(ComposerReflowWatch(
            responseID: responseID,
            composerTop: composerTop,
            gap: gap
        ))
        Log.ui.info("Transcript.composerReflow chat=\(chatID) mode=watching block=\(responseID) gap=\(Int(gap)) target=\(Int(ChatViewportLayout.responseComposerSpacing)) reason=\(reason)")
        prepareComposerReflow()
    }

    private func prepareComposerReflow() {
        guard case .watching(var watch) = composerReflow,
              let composerTop,
              let responseBottom = responseBottoms[watch.responseID],
              let frame else { return }
        if composerTop > watch.composerTop + Self.spacingTolerance {
            watch.composerTop = composerTop
            watch.gap = composerTop - responseBottom
            composerReflow = .watching(watch)
            return
        }
        let composerRise = watch.composerTop - composerTop
        guard composerRise > Self.spacingTolerance else { return }
        let gap = composerTop - responseBottom
        let correction = ChatViewportLayout.responseComposerSpacing - gap
        guard correction > Self.spacingTolerance else { return }
        let session = ComposerReflowSession(
            responseID: watch.responseID,
            initialGap: watch.gap
        )
        let request = ComposerReflowRequest(
            id: session.id,
            responseID: session.responseID,
            targetY: frame.visualTop + correction
        )
        composerReflow = .requested(session, request)
        Log.ui.info("Transcript.composerReflow chat=\(chatID) request=\(session.id) block=\(session.responseID) initialGap=\(Int(session.initialGap)) gap=\(Int(gap)) composerRise=\(Int(composerRise)) correction=\(Int(correction))")
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
