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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let minimumDistance: CGFloat = 8
    private let horizontalIntentRatio: CGFloat = 1.2
    private let maximumBlurRadius: CGFloat = 5

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
        blurAllowed ? maximumBlurRadius * min(1, progress * 5) : 0
    }

    var body: some View {
        ZStack(alignment: .leading) {
            workspace
                .environment(\.sidebarInteraction, interaction)
                .safeAreaPadding(safeAreaInsets)
                .ignoresSafeArea(.container)
                .blur(radius: blurRadius)
                .offset(x: reduceMotion ? 0 : travel * 0.4)
                .opacity(max(0, 1 - Double(progress) * 1.5))
                .allowsHitTesting(page == .workspace && !interaction.actionsSuppressed)
                .accessibilityHidden(page != .workspace)

            sidebar
                .frame(width: size.width)
                .offset(x: reduceMotion ? 0 : (travel - size.width) * 2 / 3)
                .opacity(progress)
                .allowsHitTesting(page == .sidebar && !interaction.actionsSuppressed)
                .accessibilityHidden(page != .sidebar)
        }
        .background(Theme.Colors.conversationSurface, ignoresSafeAreaEdges: .all)
        .contentShape(Rectangle())
        .simultaneousGesture(pageDrag, isEnabled: gestureEnabled)
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
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            page = target
            dragPhase = .idle
        } completion: {
            interaction.dragActive = false
            if opensSidebar, page == .sidebar, dragPhase == .idle { onOpened() }
        }
        Task { @MainActor in
            await Task.yield()
            interaction.actionsSuppressed = false
        }
    }
}
