import SwiftUI

@Observable
final class SidebarInteraction {
    static let defaultValue = SidebarInteraction()
    private struct PageSwitchExclusion {
        let bounds: CGRect
        let includesAreaBelow: Bool

        func contains(_ point: CGPoint) -> Bool {
            includesAreaBelow ? point.y >= bounds.minY : bounds.contains(point)
        }
    }

    var dragActive = false
    var actionsSuppressed = false
    private var pageSwitchExclusions: [UUID: PageSwitchExclusion] = [:]

    func setPageSwitchExclusion(owner: UUID, bounds: CGRect, includesAreaBelow: Bool) {
        pageSwitchExclusions[owner] = PageSwitchExclusion(bounds: bounds, includesAreaBelow: includesAreaBelow)
    }

    func clearPageSwitchExclusion(owner: UUID) {
        pageSwitchExclusions.removeValue(forKey: owner)
    }

    func excludesPageSwitch(at point: CGPoint) -> Bool {
        pageSwitchExclusions.values.contains { $0.contains(point) }
    }
}

extension EnvironmentValues {
    @Entry var sidebarInteraction = SidebarInteraction.defaultValue
}

private struct PageSwitchExclusionModifier: ViewModifier {
    let includesAreaBelow: Bool
    @Environment(\.sidebarInteraction) private var sidebarInteraction
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { bounds in
                sidebarInteraction.setPageSwitchExclusion(owner: owner, bounds: bounds, includesAreaBelow: includesAreaBelow)
            }
            .onDisappear {
                sidebarInteraction.clearPageSwitchExclusion(owner: owner)
            }
    }
}

extension View {
    func excludesCompactPageSwitch(includingAreaBelow: Bool = false) -> some View {
        modifier(PageSwitchExclusionModifier(includesAreaBelow: includingAreaBelow))
    }
}

private struct PageDragSettleKey: TransactionKey {
    static let defaultValue: Animation? = nil
}

private extension Transaction {
    var pageDragSettle: Animation? {
        get { self[PageDragSettleKey.self] }
        set { self[PageDragSettleKey.self] = newValue }
    }
}

enum CompactPage: String {
    case sidebar
    case workspace
}

struct CompactPageLayout<Sidebar: View, Workspace: View>: View {
    private enum DragPhase: Equatable {
        case idle
        case rejected
        case active(origin: CompactPage, translation: CGFloat)

        var translation: CGFloat {
            guard case .active(_, let translation) = self else { return 0 }
            return translation
        }
    }

    private enum WorkspaceStage {
        case onstage
        case parked
    }

    @Binding var page: CompactPage
    let size: CGSize
    let safeAreaInsets: EdgeInsets
    let interaction: SidebarInteraction
    let gestureEnabled: Bool
    let onOpeningDrag: () -> Void
    let onOpened: () -> Void
    let sidebar: Sidebar
    let workspace: Workspace

    @State private var dragPhase = DragPhase.idle
    @State private var workspaceStage = WorkspaceStage.onstage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let minimumDistance: CGFloat = 8
    private let horizontalIntentRatio: CGFloat = 1.2
    private let maximumBlurRadius: CGFloat = 28
    private let hiddenWorkspaceDimming = 0.85
    private let restingWorkspaceOpacity = 0.02
    private let sidebarEntranceDelay = 0.05
    private let sidebarReveal: ClosedRange<CGFloat> = 0.05...0.2
    private let sidebarExit = Animation.linear(duration: 0.13)
    private let sidebarExitFade = Animation.linear(duration: 0.05).delay(0.08)

    private var travel: CGFloat {
        let settled = page == .sidebar ? size.width : 0
        return min(size.width, max(0, settled + dragPhase.translation))
    }

    private var progress: CGFloat {
        guard size.width > 0 else { return 0 }
        return travel / size.width
    }

    private var blurAllowed: Bool {
        !reduceMotion && !reduceTransparency
    }

    private var blurRadius: CGFloat {
        blurAllowed && interaction.dragActive ? maximumBlurRadius * progress : 0
    }

    private var workspaceOpacity: Double {
        if reduceMotion { return max(restingWorkspaceOpacity, 1 - Double(progress)) }
        return progress < 1 ? 1 - Double(progress) * hiddenWorkspaceDimming : restingWorkspaceOpacity
    }

    private var workspaceShift: CGFloat {
        reduceMotion ? 0 : travel / 2
    }

    private var sidebarShift: CGFloat {
        reduceMotion ? 0 : (travel - size.width) / 2
    }

    private var workspaceParking: CGAffineTransform {
        switch workspaceStage {
        case .onstage: .identity
        case .parked: CGAffineTransform(translationX: size.width, y: 0)
        }
    }

    private var sidebarOpacity: Double {
        if reduceMotion { return Double(progress) }
        let reveal = (progress - sidebarReveal.lowerBound) / (sidebarReveal.upperBound - sidebarReveal.lowerBound)
        return Double(min(1, max(0, reveal)))
    }

    private var sidebarMotion: Animation {
        page == .sidebar ? Theme.Animation.page.delay(sidebarEntranceDelay) : sidebarExit
    }

    private var sidebarVisibility: Animation {
        page == .sidebar ? .linear(duration: 1.0 / 60).delay(sidebarEntranceDelay) : sidebarExitFade
    }

    private func retime(_ transaction: inout Transaction, with animation: Animation) {
        guard !reduceMotion, transaction.animation != nil else { return }
        transaction.animation = animation
    }

    private func retimeSidebarMotion(_ transaction: inout Transaction) {
        retime(&transaction, with: transaction.pageDragSettle ?? sidebarMotion)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            workspace
                .environment(\.sidebarInteraction, interaction)
                .safeAreaPadding(safeAreaInsets)
                .ignoresSafeArea(.container)
                .geometryGroup()
                .blur(radius: blurRadius)
                .visualEffect { [shift = workspaceShift] view, _ in view.offset(x: shift) }
                .transformEffect(workspaceParking)
                .opacity(workspaceOpacity)
                .allowsHitTesting(page == .workspace && !interaction.actionsSuppressed)
                .accessibilityHidden(page != .workspace)

            sidebar
                .frame(width: size.width)
                .visualEffect { [shift = sidebarShift] view, _ in view.offset(x: shift) }
                .transaction(value: page) { retimeSidebarMotion(&$0) }
                .opacity(sidebarOpacity)
                .transaction(value: page) { retime(&$0, with: sidebarVisibility) }
                .allowsHitTesting(page == .sidebar && !interaction.actionsSuppressed)
                .accessibilityHidden(page != .sidebar)
        }
        .background(Theme.Colors.conversationSurface, ignoresSafeAreaEdges: .all)
        .contentShape(Rectangle())
        .simultaneousGesture(pageDrag, isEnabled: gestureEnabled)
        .transaction(value: page) { transaction in
            transaction.addAnimationCompletion(criteria: .logicallyComplete) { parkWorkspaceWhenResting() }
        }
        .onChange(of: page) { _, page in
            if page == .workspace { workspaceStage = .onstage }
        }
    }

    private func parkWorkspaceWhenResting() {
        guard page == .sidebar, dragPhase == .idle, workspaceStage == .onstage else { return }
        workspaceStage = .parked
        Log.ui.info("RootView.workspaceStage stage=parked")
    }

    private var pageDrag: some Gesture {
        DragGesture(minimumDistance: minimumDistance, coordinateSpace: .global)
            .onChanged { value in
                switch dragPhase {
                case .idle:
                    guard !SelectableTextSelection.isActive else {
                        dragPhase = .rejected
                        Log.ui.info("RootView.sidebarDrag phase=rejected reason=textSelection")
                        return
                    }
                    guard page != .workspace || !interaction.excludesPageSwitch(at: value.startLocation) else {
                        dragPhase = .rejected
                        Log.ui.info("RootView.sidebarDrag phase=rejected reason=pageSwitchExclusion")
                        return
                    }
                    let horizontal = abs(value.translation.width) > abs(value.translation.height) * horizontalIntentRatio
                    let correctDirection = page == .workspace
                        ? value.translation.width > 0
                        : value.translation.width < 0
                    guard horizontal, correctDirection else {
                        dragPhase = .rejected
                        return
                    }
                    if page == .workspace { onOpeningDrag() }
                    interaction.dragActive = true
                    interaction.actionsSuppressed = true
                    workspaceStage = .onstage
                    dragPhase = .active(
                        origin: page,
                        translation: translation(value.translation.width, from: page)
                    )
                    Log.ui.info("RootView.sidebarDrag phase=start page=\(page.rawValue) translation=\(Int(value.translation.width))")
                case .active(let origin, _):
                    dragPhase = .active(
                        origin: origin,
                        translation: translation(value.translation.width, from: origin)
                    )
                case .rejected:
                    return
                }
            }
            .onEnded { value in
                guard case .active(let origin, let translation) = dragPhase else {
                    dragPhase = .idle
                    return
                }
                let predicted = origin == .workspace
                    ? value.predictedEndTranslation.width
                    : -value.predictedEndTranslation.width
                let changesPage = max(abs(translation), predicted) > size.width * 0.3
                let target = changesPage ? opposite(of: origin) : origin
                Log.ui.info("RootView.sidebarDrag phase=end origin=\(origin.rawValue) translation=\(Int(translation)) predicted=\(Int(predicted)) target=\(target.rawValue)")
                settle(on: target, velocity: value.velocity.width)
            }
    }

    private func translation(_ translation: CGFloat, from origin: CompactPage) -> CGFloat {
        switch origin {
        case .workspace:
            min(size.width, max(0, translation))
        case .sidebar:
            min(0, max(-size.width, translation))
        }
    }

    private func opposite(of page: CompactPage) -> CompactPage {
        page == .sidebar ? .workspace : .sidebar
    }

    private func settle(on target: CompactPage, velocity: CGFloat) {
        let opensSidebar = page == .workspace && target == .sidebar
        let destination = target == .sidebar ? size.width : 0
        let distance = destination - travel
        let initialVelocity = abs(distance) > 1 ? min(10, max(-10, velocity / distance)) : 0
        let animation = reduceMotion ? Theme.Animation.press : Animation.interpolatingSpring(
            duration: 0.32,
            bounce: 0,
            initialVelocity: initialVelocity
        )
        var transaction = Transaction(animation: animation)
        transaction.pageDragSettle = animation
        transaction.addAnimationCompletion(criteria: .logicallyComplete) {
            interaction.dragActive = false
            if opensSidebar, page == .sidebar, dragPhase == .idle { onOpened() }
            parkWorkspaceWhenResting()
        }
        withTransaction(transaction) {
            page = target
            dragPhase = .idle
        }
        Task { @MainActor in
            await Task.yield()
            interaction.actionsSuppressed = false
        }
    }
}
