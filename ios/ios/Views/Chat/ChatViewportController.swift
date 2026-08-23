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

    private enum Recorded {
        case geometry(Frame, Motion)
        case phase(ScrollPhase, ScrollPhase)
        case gesture
        case focus(Bool, String)
        case programmatic(Target)
        case page(UUID)
    }

    private struct Entry {
        let at: Date
        let recorded: Recorded
    }

    #if targetEnvironment(simulator)
    struct DebugSnapshot: Encodable {
        let chatID: String
        let frame: String?
        let position: String
        let owner: String
        let restingFromEnd: Int
        let jumpDistance: Int
        let jumpThreshold: Int
        let insetsSettling: Bool
        let showsJumpButton: Bool
        let history: [String]
    }
    #endif

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
    @ObservationIgnored private var entries = [Entry?](repeating: nil, count: 64)
    @ObservationIgnored private var entryIndex = 0

    func openAtBottom(chatID: String, onSettled: @escaping () -> Void) {
        self.chatID = chatID
        #if targetEnvironment(simulator)
        DebugCommandRouter.viewportController = self
        #endif
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
        record(.page(id))
        position.scrollTo(id: id, anchor: .top)
        Log.ui.info("Transcript.pageAnchor chat=\(chatID) block=\(id)")
    }

    func focusChanged(_ focused: Bool, slack: CGFloat) {
        guard inputFocused != focused else { return }
        inputFocused = focused
        if focused {
            guard let frame else {
                viewportHold = nil
                record(.focus(true, "none"))
                Log.ui.info("Transcript.focus chat=\(chatID) focused=true hold=none")
                return
            }
            viewportHold = if frame.jumpDistance <= Self.jumpThreshold {
                .tail(TailHold(
                    floorTop: frame.visualTop,
                    fromEnd: slack
                ))
            } else {
                .reader(top: frame.visualTop)
            }
        }
        let label = viewportHold?.label ?? "none"
        record(.focus(focused, label))
        applyViewportHold()
        Log.ui.info("Transcript.focus chat=\(chatID) focused=\(focused) hold=\(label)")
    }

    func viewportResized() {
        guard let viewportHold else { return }
        applyViewportHold()
    }

    func phaseChanged(from old: ScrollPhase, to new: ScrollPhase) {
        record(.phase(old, new))
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
        record(.gesture)
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
        record(.geometry(new, motion))
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
        record(.programmatic(target))
    }

    private func updateJumpButton(_ frame: Frame) {
        let shows = frame.jumpDistance > Self.jumpThreshold
        guard shows != showsJumpButton else { return }
        showsJumpButton = shows
        Log.ui.info("Transcript.jumpButton chat=\(chatID) shows=\(shows) fromEnd=\(Int(frame.distanceFromEnd)) inset=\(Int(frame.insetBottom))")
    }

    private func describePosition() -> String {
        if let edge = position.edge { return "edge(\(edge))" }
        if let id = position.viewID(type: UUID.self) { return "id(\(id.uuidString.prefix(8)))" }
        if let point = position.point { return "point(\(Int(point.y)))" }
        return "none"
    }

    private func record(_ recorded: Recorded) {
        entries[entryIndex] = Entry(at: .now, recorded: recorded)
        entryIndex = (entryIndex + 1) % entries.count
    }

    private func recentHistory(limit: Int) -> [String] {
        let now = Date.now
        var lines: [String] = []
        for offset in 0..<entries.count {
            guard let entry = entries[(entryIndex + offset) % entries.count] else { continue }
            let age = String(format: "%.2f", now.timeIntervalSince(entry.at))
            lines.append("-\(age)s \(describe(entry.recorded))")
        }
        return Array(lines.suffix(limit))
    }

    private func describe(_ recorded: Recorded) -> String {
        switch recorded {
        case let .geometry(frame, motion): "geo \(motion.label) \(frame.summary)"
        case let .phase(old, new): "phase \(String(describing: old)) -> \(String(describing: new))"
        case .gesture: "gesture"
        case let .focus(focused, hold): "focus focused=\(focused) hold=\(hold)"
        case .programmatic(let target): "programmatic \(target.label)"
        case .page(let id): "page anchor \(id.uuidString.prefix(8))"
        }
    }

    #if targetEnvironment(simulator)
    func debugSnapshot() -> DebugSnapshot {
        DebugSnapshot(
            chatID: chatID,
            frame: frame?.summary,
            position: describePosition(),
            owner: motion.label,
            restingFromEnd: Int(max(0, frame?.distanceFromEnd ?? 0)),
            jumpDistance: Int(frame?.jumpDistance ?? 0),
            jumpThreshold: Int(Self.jumpThreshold),
            insetsSettling: false,
            showsJumpButton: showsJumpButton,
            history: recentHistory(limit: 24)
        )
    }
    #endif
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
