import QuartzCore
import SwiftUI

@MainActor
@Observable
final class ConversationViewportController {
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
        let slack: CGFloat
        let restingInset: CGFloat
        var lifted = false

        var pinsEnd: Bool { slack == 0 }

        func rests(in frame: Frame) -> Bool {
            frame.insetBottom <= restingInset + 0.5
        }

        func expectedTop(in frame: Frame) -> CGFloat {
            let endTop = max(0, frame.visualTop + frame.distanceFromEnd)
            guard lifted else { return min(floorTop, endTop) }
            return min(max(floorTop, endTop - slack), endTop)
        }

        var label: String {
            "floor=\(Int(floorTop)) slack=\(Int(slack)) lifted=\(lifted)"
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

        func settles(in frame: Frame) -> Bool {
            switch self {
            case .tail(let hold): hold.rests(in: frame) && abs(frame.visualTop - hold.expectedTop(in: frame)) <= 1
            case .reader(let top): abs(frame.visualTop - top) <= 1
            }
        }

        mutating func observe(_ frame: Frame) {
            guard case .tail(var hold) = self, !hold.lifted, !hold.rests(in: frame) else { return }
            hold.lifted = true
            self = .tail(hold)
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

    private enum Presentation {
        case opening(() -> Void)
        case sending(UUID)
        case followingTurn(UUID)
        case reading
    }

    private static let jumpThreshold: CGFloat = 32
    private static let keyboardAnimation = Animation.spring(duration: 0.26, bounce: 0)

    private(set) var showsJumpButton = false
    private(set) var sizeChangeAnchor: UnitPoint?
    var position = ScrollPosition(edge: .bottom)

    var isUserScrolling: Bool {
        if case .user = motion { return true }
        return false
    }

    var visibleBlockID: UUID? { position.viewID(type: UUID.self) }

    @ObservationIgnored private(set) var anchorContentHeight: CGFloat = 0
    @ObservationIgnored var transcriptTail: CGFloat = 0
    @ObservationIgnored private var conversationID = ""
    @ObservationIgnored private var frame: Frame?
    @ObservationIgnored private var motion = Motion.stationary
    @ObservationIgnored private var viewportHold: ViewportHold? {
        didSet { updateSizeChangeAnchor() }
    }
    @ObservationIgnored private var inputFocused = false
    @ObservationIgnored private var visibleTargetID: UUID?
    @ObservationIgnored private var pendingFrame: Frame?
    @ObservationIgnored private var animatingCorrectionTop: CGFloat?
    @ObservationIgnored private var presentation = Presentation.reading {
        didSet { updateSizeChangeAnchor() }
    }
    @ObservationIgnored private var layoutLogStart: Frame?
    @ObservationIgnored private var layoutLogEnd: Frame?
    @ObservationIgnored private var layoutLogTask: Task<Void, Never>?
    @ObservationIgnored private lazy var geometryFrameDriver = ConversationViewportFrameDriver { [weak self] in
        self?.commitPendingGeometry()
    }

    func openAtBottom(conversationID: String, onSettled: @escaping () -> Void) {
        self.conversationID = conversationID
        pendingFrame = pendingFrame ?? frame
        frame = nil
        viewportHold = nil
        inputFocused = false
        visibleTargetID = nil
        presentation = .opening(onSettled)
        resetLayoutLog()
        showsJumpButton = false
        move(to: .bottom)
        position.scrollTo(edge: .bottom)
        if pendingFrame != nil { geometryFrameDriver.schedule() }
    }

    func close() {
        presentation = .reading
        frame = nil
        pendingFrame = nil
        geometryFrameDriver.cancel()
        resetLayoutLog()
    }

    func holdForSend(_ id: UUID) {
        presentation = .sending(id)
        showsJumpButton = false
        viewportHold = nil
    }

    func beginSendHandoff(_ id: UUID) {
        holdForSend(id)
        move(to: .turnTop(id))
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            position.scrollTo(id: id, anchor: .top)
        }
        Log.ui.info("ConversationUX.intent conversation=\(conversationID) kind=sendPlacement target=\(id) \(logSnapshot)")
    }

    func cancelSendHandoff() {
        if case .sending = presentation { presentation = .reading }
    }

    func endSendHandoff() {
        guard case .sending(let id) = presentation else { return }
        presentation = .followingTurn(id)
        if let frame = pendingFrame ?? frame { updateJumpButton(frame) }
        preserveTurn(id)
    }

    func preserveTurn(_ id: UUID) {
        switch presentation {
        case .sending(let targetID), .followingTurn(let targetID):
            guard targetID == id else { return }
        case .opening, .reading: return
        }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            position.scrollTo(id: id, anchor: .top)
        }
        Log.ui.info("ConversationUX.intent conversation=\(conversationID) kind=preserveSubmission target=\(id) \(logSnapshot)")
    }

    func rideToBottom() {
        presentation = .reading
        guard frame?.jumpDistance ?? .infinity > 1 else {
            motion = .stationary
            position.scrollTo(edge: .bottom)
            Log.ui.info("ConversationUX.intent conversation=\(conversationID) kind=scroll target=bottom disposition=alreadyAtBottom \(logSnapshot)")
            return
        }
        move(to: .bottom)
        Log.ui.info("ConversationUX.intent conversation=\(conversationID) kind=scroll target=bottom disposition=animated \(logSnapshot)")
        withAnimation(Theme.Animation.drop) {
            position.scrollTo(edge: .bottom)
        }
    }

    func preservePageAnchor(_ id: UUID) {
        presentation = .reading
        position.scrollTo(id: id, anchor: .top)
        Log.ui.info("ConversationUX.intent conversation=\(conversationID) kind=pageAnchor target=\(id) anchor=top \(logSnapshot)")
    }

    func focusChanged(_ focused: Bool, slack: CGFloat, source: String) {
        guard inputFocused != focused else { return }
        inputFocused = focused
        if focused {
            guard let frame else {
                viewportHold = nil
                Log.ui.info("ConversationUX.intent conversation=\(conversationID) kind=focus source=\(source) focused=true hold=none \(logSnapshot)")
                return
            }
            let consumableSlack = max(0, slack - ConversationViewportLayout.responseComposerSpacing)
            viewportHold = if frame.jumpDistance - slack <= Self.jumpThreshold {
.tail(TailHold(floorTop: frame.visualTop, slack: consumableSlack, restingInset: frame.insetBottom))
            } else {
                .reader(top: frame.visualTop)
            }
        }
        let label = viewportHold?.label ?? "none"
        applyViewportHold()
        Log.ui.info("ConversationUX.intent conversation=\(conversationID) kind=focus source=\(source) focused=\(focused) slack=\(Int(slack)) hold=\(label) \(logSnapshot)")
    }

    func visibleTargetsChanged(_ ids: [UUID]) {
        visibleTargetID = ids.first
    }

    func measureAnchorContent(_ height: CGFloat) {
        anchorContentHeight = height
    }

    func viewportResized() {
        guard viewportHold != nil else { return }
        applyViewportHold()
    }

    func phaseChanged(from old: ScrollPhase, to new: ScrollPhase) {
        guard old != new else { return }
        if new.isUserDriven {
            switch presentation {
            case .followingTurn, .sending: presentation = .reading
            case .opening, .reading: break
            }
            viewportHold = nil
            motion = .user(new)
        } else if new == .idle {
            motion = .stationary
        }
        Log.ui.info("ConversationUX.motion conversation=\(conversationID) phase=\(String(describing: old))->\(String(describing: new)) \(logSnapshot)")
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
        if old == nil {
            Log.ui.info("ConversationUX.geometry conversation=\(conversationID) source=scroll \(new.summary) owner=\(motion.label)")
        }
        stageLayoutLog(from: old, to: new)
        if case .opening(let completion) = presentation {
            guard new.container > 0 else { return }
            if followBottom(new) { return }
            presentation = .reading
            motion = .stationary
            showsJumpButton = false
            completion()
            Log.ui.info("ConversationUX.lifecycle conversation=\(conversationID) phase=viewportSettled \(logSnapshot)")
            return
        }
        updateJumpButton(new)
        let keyboardMoved = old.map { abs($0.insetBottom - new.insetBottom) > 0.5 } ?? false
        viewportHold?.observe(new)
        applyViewportHold(animation: keyboardMoved ? Self.keyboardAnimation : nil)
        if case .programmatic(.bottom) = motion, new.distanceFromEnd <= 1 {
            motion = .stationary
        } else if case .programmatic(.viewportClearance) = motion {
            motion = .stationary
        }
        if !inputFocused,
           viewportHold?.settles(in: new) == true {
            self.viewportHold = nil
        }
    }

    private func followBottom(_ frame: Frame) -> Bool {
        guard frame.container > 0, frame.distanceFromEnd > 1 else { return false }
        move(to: .bottom)
        position.scrollTo(edge: .bottom)
        Log.ui.info("ConversationUX.intent conversation=\(conversationID) kind=openingCorrection \(logSnapshot)")
        return true
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
        let message = "ConversationUX.layout conversation=\(conversationID) region=scrollGeometry top=\(Int(start.visualTop.rounded()))->\(Int(end.visualTop.rounded())) fromEnd=\(Int(start.distanceFromEnd.rounded()))->\(Int(end.distanceFromEnd.rounded())) content=\(Int(start.content.rounded()))->\(Int(end.content.rounded())) container=\(Int(start.container.rounded()))->\(Int(end.container.rounded())) insets=\(Int(start.insetTop.rounded()))/\(Int(start.insetBottom.rounded()))->\(Int(end.insetTop.rounded()))/\(Int(end.insetBottom.rounded())) visible=\(visibleTargetID?.uuidString ?? visibleBlockID?.uuidString ?? "none") owner=\(motion.label) focused=\(inputFocused)"
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

    private func applyViewportHold(animation: Animation? = nil) {
        if case .sending = presentation { return }
        guard let frame, let viewportHold else { return }
        let top = viewportHold.expectedTop(in: frame)
        guard abs(top - frame.visualTop) > 0.5 else {
            animatingCorrectionTop = nil
            return
        }
        if let animatingCorrectionTop, abs(animatingCorrectionTop - top) <= 0.5 { return }
        animatingCorrectionTop = animation == nil ? nil : top
        move(to: .viewportClearance)
        withAnimation(animation) {
            position.scrollTo(y: top)
        }
        Log.ui.info("ConversationUX.intent conversation=\(conversationID) kind=viewportCorrection targetTop=\(Int(top)) hold=\(viewportHold.label) \(logSnapshot)")
    }

    private func move(to target: Target) {
        if target != .viewportClearance {
            viewportHold = nil
        }
        motion = .programmatic(target)
    }

    private func updateSizeChangeAnchor() {
        let anchor: UnitPoint? = pinsEnd ? .bottom : nil
        guard anchor != sizeChangeAnchor else { return }
        sizeChangeAnchor = anchor
    }

    private var pinsEnd: Bool {
        switch presentation {
        case .opening: return true
        case .sending, .followingTurn, .reading: break
        }
        if case .tail(let hold) = viewportHold { return hold.pinsEnd }
        return false
    }

    private func updateJumpButton(_ frame: Frame) {
        if case .sending = presentation { return }
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
private final class ConversationViewportFrameDriver {
    private var link: CADisplayLink?
    private let handler: @MainActor () -> Void

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    func schedule() {
        guard link == nil else { return }
        let proxy = ConversationViewportFrameProxy { [weak self] in
            self?.fire()
        }
        let link = CADisplayLink(target: proxy, selector: #selector(ConversationViewportFrameProxy.fire))
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
private final class ConversationViewportFrameProxy: NSObject {
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
