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
    @ObservationIgnored private var visibleTargetID: UUID?
    @ObservationIgnored private var pendingFrame: Frame?
    @ObservationIgnored private var pendingOpenCompletion: (() -> Void)?
    @ObservationIgnored private var layoutLogStart: Frame?
    @ObservationIgnored private var layoutLogEnd: Frame?
    @ObservationIgnored private var layoutLogTask: Task<Void, Never>?
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
        visibleTargetID = nil
        pendingOpenCompletion = onSettled
        resetLayoutLog()
        showsJumpButton = false
        move(to: .bottom)
        position.scrollTo(edge: .bottom)
    }

    func rideToTurn(_ id: UUID, animated: Bool, scroll: () -> Void) {
        let target = Target.turnTop(id)
        move(to: target)
        Log.ui.info("ChatUX.intent chat=\(chatID) kind=scroll target=\(target.label) anchor=top animated=\(animated) \(logSnapshot)")
        guard animated else {
            scroll()
            return
        }
        withAnimation(Theme.Animation.ride) {
            scroll()
        }
    }

    func rideToBottom() {
        guard frame?.jumpDistance ?? .infinity > 1 else {
            motion = .stationary
            position.scrollTo(edge: .bottom)
            Log.ui.info("ChatUX.intent chat=\(chatID) kind=scroll target=bottom disposition=alreadyAtBottom \(logSnapshot)")
            return
        }
        move(to: .bottom)
        Log.ui.info("ChatUX.intent chat=\(chatID) kind=scroll target=bottom disposition=animated \(logSnapshot)")
        withAnimation(.easeOut(duration: Theme.Animation.drop)) {
            position.scrollTo(edge: .bottom)
        }
    }

    func preservePageAnchor(_ id: UUID) {
        position.scrollTo(id: id, anchor: .top)
        Log.ui.info("ChatUX.intent chat=\(chatID) kind=pageAnchor target=\(id) anchor=top \(logSnapshot)")
    }

    func focusChanged(_ focused: Bool, slack: CGFloat, source: String) {
        guard inputFocused != focused else { return }
        inputFocused = focused
        if focused {
            guard let frame else {
                viewportHold = nil
                Log.ui.info("ChatUX.intent chat=\(chatID) kind=focus source=\(source) focused=true hold=none \(logSnapshot)")
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
        Log.ui.info("ChatUX.intent chat=\(chatID) kind=focus source=\(source) focused=\(focused) slack=\(Int(slack)) hold=\(label) \(logSnapshot)")
    }

    func visibleTargetsChanged(_ ids: [UUID]) {
        visibleTargetID = ids.first
    }

    func viewportResized() {
        guard viewportHold != nil else { return }
        applyViewportHold()
    }

    func phaseChanged(from old: ScrollPhase, to new: ScrollPhase) {
        guard old != new else { return }
        if new.isUserDriven {
            viewportHold = nil
            motion = .user(new)
        } else if new == .idle {
            motion = .stationary
        }
        Log.ui.info("ChatUX.motion chat=\(chatID) phase=\(String(describing: old))->\(String(describing: new)) \(logSnapshot)")
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
        let old = frame
        frame = new
        stageLayoutLog(from: old, to: new)
        updateJumpButton(new)
        applyViewportHold()
        if case .programmatic(.bottom) = motion, new.distanceFromEnd <= 1 {
            motion = .stationary
            let completion = pendingOpenCompletion
            pendingOpenCompletion = nil
            completion?()
            Log.ui.info("ChatUX.lifecycle chat=\(chatID) phase=viewportSettled \(logSnapshot)")
        } else if case .programmatic(.viewportClearance) = motion {
            motion = .stationary
        }
        if !inputFocused,
           let viewportHold,
           abs(new.visualTop - viewportHold.floorTop) <= 1 {
            self.viewportHold = nil
        }
    }

    private func stageLayoutLog(from old: Frame?, to new: Frame) {
        guard let old else { return }
        let contentChanged = abs(new.content - old.content) > 0.5
        let containerChanged = abs(new.container - old.container) > 0.5
        let insetsChanged = abs(new.insetTop - old.insetTop) > 0.5
            || abs(new.insetBottom - old.insetBottom) > 0.5
        guard contentChanged || containerChanged || insetsChanged else { return }
        if layoutLogStart == nil {
            layoutLogStart = old
        }
        layoutLogEnd = new
        layoutLogTask?.cancel()
        layoutLogTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            self?.flushLayoutLog()
        }
    }

    private func flushLayoutLog() {
        layoutLogTask = nil
        guard let start = layoutLogStart, let end = layoutLogEnd else { return }
        let message = "ChatUX.layout chat=\(chatID) region=scrollGeometry top=\(Int(start.visualTop.rounded()))->\(Int(end.visualTop.rounded())) fromEnd=\(Int(start.distanceFromEnd.rounded()))->\(Int(end.distanceFromEnd.rounded())) content=\(Int(start.content.rounded()))->\(Int(end.content.rounded())) container=\(Int(start.container.rounded()))->\(Int(end.container.rounded())) insets=\(Int(start.insetTop.rounded()))/\(Int(start.insetBottom.rounded()))->\(Int(end.insetTop.rounded()))/\(Int(end.insetBottom.rounded())) visible=\(visibleTargetID?.uuidString ?? visibleBlockID?.uuidString ?? "none") owner=\(motion.label) focused=\(inputFocused)"
        layoutLogStart = nil
        layoutLogEnd = nil
        Log.ui.info(message)
    }

    private func resetLayoutLog() {
        layoutLogTask?.cancel()
        layoutLogTask = nil
        layoutLogStart = nil
        layoutLogEnd = nil
    }

    private func applyViewportHold() {
        guard let frame, let viewportHold else { return }
        let top = viewportHold.expectedTop(in: frame)
        guard abs(top - frame.visualTop) > 0.5 else { return }
        move(to: .viewportClearance)
        position.scrollTo(y: top)
        Log.ui.info("ChatUX.intent chat=\(chatID) kind=viewportCorrection targetTop=\(Int(top)) hold=\(viewportHold.label) \(logSnapshot)")
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
    }

    private var logSnapshot: String {
        let visible = visibleTargetID?.uuidString ?? visibleBlockID?.uuidString ?? "none"
        return "frame=\(frame?.summary ?? "none") visible=\(visible) owner=\(motion.label) focused=\(inputFocused)"
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
