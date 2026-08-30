import QuartzCore
import SwiftUI

@MainActor
@Observable
final class ChatViewportController {
    enum Target: Equatable {
        case turnTop(UUID)
        case bottom
        case viewportClearance

        var label: String {
            switch self {
            case .turnTop(let id): "turnTop(\(id.uuidString.prefix(8)))"
            case .bottom: "bottom"
            case .viewportClearance: "viewportClearance"
            }
        }
    }

    private struct TailHold: Equatable {
        let floorTop: CGFloat
        let fromEnd: CGFloat

        func expectedTop(in frame: Frame) -> CGFloat {
            let endTop = max(0, frame.visualTop + frame.distanceFromEnd)
            return min(max(floorTop, endTop - fromEnd), endTop)
        }

        var label: String {
            "floor=\(Int(floorTop)) fromEnd=\(Int(fromEnd))"
        }
    }

    private enum ViewportHold: Equatable {
        case tail(TailHold)
        case reader(top: CGFloat)

        func expectedTop(in frame: Frame) -> CGFloat {
            switch self {
            case .tail(let hold): hold.expectedTop(in: frame)
            case .reader(let top): min(top, frame.endTop)
            }
        }

        var floorTop: CGFloat {
            switch self {
            case .tail(let hold): hold.floorTop
            case .reader(let top): top
            }
        }

        var label: String {
            switch self {
            case .tail(let hold): "tail \(hold.label)"
            case .reader(let top): "reader top=\(Int(top))"
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

        var endTop: CGFloat {
            max(0, visualTop + distanceFromEnd)
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
    var position = ScrollPosition(edge: .bottom)

    var isUserScrolling: Bool {
        if case .user = motion { return true }
        return false
    }

    var visibleBlockID: UUID? { position.viewID(type: UUID.self) }

    @ObservationIgnored private var chatID = ""
    @ObservationIgnored private var frame: Frame?
    @ObservationIgnored private var motion = Motion.stationary
    @ObservationIgnored private var viewportHold: ViewportHold?
    @ObservationIgnored private var inputFocused = false
    @ObservationIgnored private var pendingFrame: Frame?
    @ObservationIgnored private var pendingOpenCompletion: (() -> Void)?
    @ObservationIgnored private lazy var geometryFrameDriver = ChatViewportFrameDriver { [weak self] in
        self?.commitPendingGeometry()
    }

    func openAtBottom(chatID: String, onSettled: @escaping () -> Void) {
        self.chatID = chatID
        frame = nil
        pendingFrame = nil
        geometryFrameDriver.cancel()
        viewportHold = nil
        inputFocused = false
        pendingOpenCompletion = onSettled
        showsJumpButton = false
        move(to: .bottom)
        position.scrollTo(edge: .bottom)
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

    func rideToBottom() {
        Log.ui.info("Transcript.anchor chat=\(chatID) target=bottom")
        guard frame?.jumpDistance ?? .infinity > 1 else {
            motion = .stationary
            position.scrollTo(edge: .bottom)
            return
        }
        move(to: .bottom)
        withAnimation(.easeOut(duration: Theme.Animation.drop)) {
            position.scrollTo(edge: .bottom)
        }
    }

    func preservePageAnchor(_ id: UUID) {
        position.scrollTo(id: id, anchor: .top)
        Log.ui.info("Transcript.pageAnchor chat=\(chatID) block=\(id)")
    }

    func focusChanged(_ focused: Bool, slack: CGFloat) {
        guard inputFocused != focused else { return }
        inputFocused = focused
        if focused {
            guard let frame else {
                viewportHold = nil
                Log.ui.info("Transcript.focus chat=\(chatID) focused=true hold=none")
                return
            }
            viewportHold = if frame.jumpDistance - slack <= Self.jumpThreshold {
                .tail(TailHold(
                    floorTop: frame.visualTop,
                    fromEnd: slack
                ))
            } else {
                .reader(top: frame.visualTop)
            }
        }
        let label = viewportHold?.label ?? "none"
        applyViewportHold()
        Log.ui.info("Transcript.focus chat=\(chatID) focused=\(focused) slack=\(Int(slack)) hold=\(label) frame=\(frame?.summary ?? "none")")
    }

    func viewportResized() {
        guard viewportHold != nil else { return }
        applyViewportHold()
    }

    func phaseChanged(from old: ScrollPhase, to new: ScrollPhase) {
        if new.isUserDriven {
            motion = .user(new)
        } else if new == .idle {
            motion = .stationary
        }
        Log.ui.info("Transcript.phase chat=\(chatID) \(String(describing: old)) -> \(String(describing: new)) owner=\(motion.label)")
    }

    func gestureStarted() {
        viewportHold = nil
        guard !isUserScrolling else { return }
        motion = .user(.tracking)
        Log.ui.info("Transcript.gestureStart chat=\(chatID)")
    }

    func geometryChanged(_ new: Frame) {
        pendingFrame = new
        geometryFrameDriver.schedule()
    }

    private func commitPendingGeometry() {
        guard let pendingFrame else { return }
        self.pendingFrame = nil
        commitGeometry(pendingFrame)
    }

    private func commitGeometry(_ new: Frame) {
        frame = new
        updateJumpButton(new)
        applyViewportHold()
        if case .programmatic(.bottom) = motion, new.distanceFromEnd <= 1 {
            motion = .stationary
            let completion = pendingOpenCompletion
            pendingOpenCompletion = nil
            completion?()
            Log.ui.info("Transcript.openSettled chat=\(chatID) \(new.summary)")
        } else if case .programmatic(.viewportClearance) = motion {
            motion = .stationary
        }
        if !inputFocused,
           let viewportHold,
           abs(new.visualTop - viewportHold.floorTop) <= 1 {
            self.viewportHold = nil
        }
    }

    private func applyViewportHold() {
        guard let frame, let viewportHold else { return }
        let top = viewportHold.expectedTop(in: frame)
        guard abs(top - frame.visualTop) > 0.5 else { return }
        move(to: .viewportClearance)
        position.scrollTo(y: top)
        Log.ui.info("Transcript.viewportClearance chat=\(chatID) top=\(Int(top)) hold=\(viewportHold.label)")
    }

    private func move(to target: Target) {
        if target != .viewportClearance {
            viewportHold = nil
        }
        motion = .programmatic(target)
    }

    private func updateJumpButton(_ frame: Frame) {
        let shows = frame.jumpDistance > Self.jumpThreshold
        guard shows != showsJumpButton else { return }
        showsJumpButton = shows
        Log.ui.info("Transcript.jumpButton chat=\(chatID) shows=\(shows) fromEnd=\(Int(frame.distanceFromEnd)) inset=\(Int(frame.insetBottom))")
    }

}

@MainActor
private final class ChatViewportFrameDriver {
    private var link: CADisplayLink?
    private let handler: @MainActor () -> Void

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    func schedule() {
        guard link == nil else { return }
        let proxy = ChatViewportFrameProxy { [weak self] in
            self?.fire()
        }
        let link = CADisplayLink(target: proxy, selector: #selector(ChatViewportFrameProxy.fire))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func cancel() {
        link?.invalidate()
        link = nil
    }

    private func fire() {
        cancel()
        handler()
    }
}

@MainActor
private final class ChatViewportFrameProxy: NSObject {
    private let handler: @MainActor () -> Void

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    @objc func fire() {
        handler()
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
