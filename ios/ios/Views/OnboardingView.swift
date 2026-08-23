import QuartzCore
import SwiftUI
import UIKit

struct OnboardingView: View {
    let onDone: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var step: Step = .welcome
    @State private var picked: PickedModel?

    private let welcomeIllustrationHeight: CGFloat = 220
    private let welcomeHeaderMinHeight: CGFloat = 136

    private enum Step: Int, CaseIterable {
        case welcome, services, ownership, controlled, proxyDisclosure
    }

    private struct PickedModel {
        let provider: String
        let model: String
    }

    var body: some View {
        TabView(selection: $step) {
            titleSlide(
                title: "Moo Moo",
                description: "Ox is a self-evolving agent\nthat lives on your mobile device."
            )
            .tag(Step.welcome)

            slide(
                title: "Acts everywhere",
                description: "Ox turns websites into reusable actions. You can use one that already exists or ask Ox to build a new one for you."
            ) {
                VStack(spacing: Theme.Spacing.md) {
                    WebsitesDemo(height: welcomeIllustrationHeight)
                    Text("“Hey Ox, add LinkedIn as a service”")
                        .font(Theme.Fonts.bodySm)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                }
                .padding(.top, Theme.Spacing.md + Theme.Spacing.sm)
            }
            .tag(Step.services)

            slide(
                title: "Yours, by design",
                description: "Ox runs on your device, keeps your data there, and works with any model, including free or self-hosted ones."
            ) {
                pickAIComponent
            } actions: {
                pickAIActions
            }
            .tag(Step.ownership)

            slide(
                title: "Peace of mind",
                description: "Ox asks before sensitive actions, keeps account credentials isolated on the web page, and lets you pull the plug at any time."
            ) {
                ApprovalDemo()
            }
            .tag(Step.controlled)

            slide(
                title: "Disclaimer",
                description: "Ox may act on your behalf, so you are responsible for evaluating the risks and granting permissions."
            ) {
                ProxyDisclosureDiagram()
            } actions: {
                VStack(spacing: Theme.Spacing.md) {
                    Button { finish() } label: { Text("Acknowledge") }
                        .buttonStyle(OnboardingCTAButton())
                        .accessibilityIdentifier(A11yID.Onboarding.complete)
                    OnboardingCommunityLinks()
                }
            }
            .tag(Step.proxyDisclosure)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .animation(.easeInOut(duration: 0.35), value: step)
        .background(Theme.Colors.surface, ignoresSafeAreaEdges: .all)
        .environment(\.locale, AppLocale.shared.locale)
    }

    private func titleSlide(
        title: LocalizedStringKey,
        description: LocalizedStringKey
    ) -> some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                VStack(spacing: Theme.Spacing.md) {
                    titleBlock(title: title)
                    Text(description)
                        .font(Theme.Fonts.bodyMd)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                }
                .frame(minHeight: welcomeHeaderMinHeight, alignment: .top)
                OnboardingCellularField(isActive: step == .welcome)
                    .frame(height: welcomeIllustrationHeight)
                    .padding(.top, Theme.Spacing.xl)
                    .accessibilityHidden(true)
                Spacer()
                pagination
                    .padding(.top, Theme.Spacing.xl)
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(.top, max(Theme.Spacing.xxl, geo.size.height * 0.16))
            .padding(.bottom, Theme.Spacing.lg)
        }
        .padding(.horizontal, Theme.Spacing.xxl)
    }

    private func slide<Component: View>(
        title: LocalizedStringKey,
        titleLead: LocalizedStringKey? = nil,
        titleTail: LocalizedStringKey? = nil,
        description: LocalizedStringKey? = nil,
        @ViewBuilder component: () -> Component
    ) -> some View {
        let componentContent = component()
        return slide(title: title, titleLead: titleLead, titleTail: titleTail, description: description) {
            componentContent
        } actions: {
            EmptyView()
        }
    }

    private func slide<Component: View, Actions: View>(
        title: LocalizedStringKey,
        titleLead: LocalizedStringKey? = nil,
        titleTail: LocalizedStringKey? = nil,
        description: LocalizedStringKey? = nil,
        @ViewBuilder component: () -> Component,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        let componentContent = component()
        let actionContent = actions()
        return GeometryReader { geo in
            let content = VStack(spacing: 0) {
                VStack(spacing: Theme.Spacing.md) {
                    inlineTitleBlock(lead: titleLead, emphasis: title, tail: titleTail)
                    if let description {
                        Text(description)
                            .font(Theme.Fonts.bodyMd)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    }
                }
                componentContent
                    .padding(.top, Theme.Spacing.xl)
                Spacer(minLength: Theme.Spacing.lg)
                actionContent
                pagination
                    .padding(.top, Theme.Spacing.xl)
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(
                .top,
                dynamicTypeSize.isAccessibilitySize
                    ? Theme.Spacing.xxl
                    : max(Theme.Spacing.xxl, geo.size.height * 0.16)
            )
            .padding(.bottom, Theme.Spacing.lg)

            if dynamicTypeSize.isAccessibilitySize {
                ScrollView(.vertical) {
                    content.frame(minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
            } else {
                content
            }
        }
        .padding(.horizontal, Theme.Spacing.xxl)
    }

    private func titleBlock(title: LocalizedStringKey) -> some View {
        Text(title)
            .font(Theme.Fonts.display)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            .minimumScaleFactor(0.75)
            .allowsTightening(true)
            .multilineTextAlignment(.center)
            .foregroundStyle(Theme.Colors.onSurface)
    }

    private func inlineTitleBlock(
        lead: LocalizedStringKey?,
        emphasis: LocalizedStringKey,
        tail: LocalizedStringKey?
    ) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                inlineTitleLabel(lead: lead, emphasis: emphasis, tail: tail)
                    .multilineTextAlignment(.center)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                    if let lead {
                        Text(lead)
                    }
                    Text(emphasis)
                    if let tail {
                        Text(tail)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
            }
        }
        .font(Theme.Fonts.display)
        .foregroundStyle(Theme.Colors.onSurface)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(inlineTitleLabel(lead: lead, emphasis: emphasis, tail: tail))
    }

    private func inlineTitleLabel(
        lead: LocalizedStringKey?,
        emphasis: LocalizedStringKey,
        tail: LocalizedStringKey?
    ) -> Text {
        switch (lead, tail) {
        case (.some(let lead), .some(let tail)):
            Text("\(Text(lead)) \(Text(emphasis)) \(Text(tail))")
        case (.some(let lead), .none):
            Text("\(Text(lead)) \(Text(emphasis))")
        case (.none, .some(let tail)):
            Text("\(Text(emphasis)) \(Text(tail))")
        case (.none, .none):
            Text(emphasis)
        }
    }

    @ViewBuilder
    private var pickAIComponent: some View {
        if let picked {
            pickedCard(picked)
        } else {
            ProviderPickerButton { provider, model in
                withAnimation(.easeOut(duration: 0.2)) {
                    self.picked = PickedModel(provider: provider, model: model)
                }
            }
        }
    }

    @ViewBuilder
    private var pickAIActions: some View {
        if picked != nil {
            Button { showDisclaimer() } label: { Text("Continue") }
                .buttonStyle(OnboardingCTAButton())
                .accessibilityIdentifier(A11yID.Onboarding.continueToDisclaimer)
        }
    }

    private func pickedCard(_ picked: PickedModel) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(verbatim: "\(picked.provider) · \(picked.model)")
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.onSurface)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.Colors.primary.opacity(0.12), in: Capsule(style: .continuous))
    }

    private var pagination: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(Step.allCases, id: \.self) { s in
                Circle()
                    .fill(s == step ? Theme.Colors.primary.dynamic : Theme.Colors.onSurfaceMuted.dynamic.opacity(0.25))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Page"))
        .accessibilityValue(Text(verbatim: "\(step.rawValue + 1)/\(Step.allCases.count)"))
        .accessibilityIdentifier(A11yID.Onboarding.pagination)
    }

    private func finish() {
        Log.ui.info("Onboarding.done picked=\(picked != nil)")
        onDone()
    }

    private func showDisclaimer() {
        withAnimation(.easeInOut(duration: 0.35)) {
            step = .proxyDisclosure
        }
    }
}

private struct OnboardingCellularField: View {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        OnboardingCellularFieldRepresentable(
            tint: UIColor(Theme.Colors.primary.dynamic),
            isActive: isActive,
            reduceMotion: reduceMotion
        )
    }
}

private struct OnboardingCellularFieldRepresentable: UIViewRepresentable {
    let tint: UIColor
    let isActive: Bool
    let reduceMotion: Bool

    func makeUIView(context: Context) -> OnboardingCellularFieldView {
        let view = OnboardingCellularFieldView()
        view.configure(tint: tint, isActive: isActive, reduceMotion: reduceMotion)
        return view
    }

    func updateUIView(_ view: OnboardingCellularFieldView, context: Context) {
        view.configure(tint: tint, isActive: isActive, reduceMotion: reduceMotion)
    }

    static func dismantleUIView(_ view: OnboardingCellularFieldView, coordinator: Void) {
        view.stopAnimating()
    }
}

private final class OnboardingCellularFieldView: UIView {
    private struct Cell: Hashable {
        let x: Int
        let y: Int
    }

    private static let sideLength = 18
    private static let cellCount = sideLength * sideLength
    private static let generationDuration = 0.24
    private static let animationGenerationCount = 512
    private static let inactiveRadius = 2
    private static let animationKey = "onboardingCellularField"
    private static let initialGeneration: Set<Cell> = [
        Cell(x: 7, y: 7), Cell(x: 10, y: 7),
        Cell(x: 7, y: 8), Cell(x: 8, y: 8), Cell(x: 9, y: 8), Cell(x: 10, y: 8),
        Cell(x: 8, y: 9), Cell(x: 9, y: 9),
        Cell(x: 8, y: 10), Cell(x: 9, y: 10)
    ]
    private static let generations: [Set<Cell>] = {
        var result = [initialGeneration]
        var generation = initialGeneration

        for _ in 1..<animationGenerationCount {
            generation = nextGeneration(after: generation)
            result.append(generation)
        }

        result.append(initialGeneration)
        return result
    }()
    private static let opacityValues: [[NSNumber]] = {
        let visibleGenerations = generations.map { expanded($0, radius: inactiveRadius) }

        return (0..<cellCount).map { index in
            let cell = Cell(x: index % sideLength, y: index / sideLength)
            return generations.indices.map { generationIndex in
                let opacity: Float
                if generations[generationIndex].contains(cell) {
                    opacity = 1
                } else if visibleGenerations[generationIndex].contains(cell) {
                    opacity = 0.055
                } else {
                    opacity = 0
                }
                return NSNumber(value: opacity)
            }
        }
    }()
    private static let timingFunctions = (0..<animationGenerationCount).map { _ in
        CAMediaTimingFunction(name: .easeInEaseOut)
    }

    private let cells = (0..<cellCount).map { _ in CALayer() }
    private var fieldTint = UIColor.clear
    private var isActive = false
    private var reduceMotion = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        cells.forEach(layer.addSublayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(tint: UIColor, isActive: Bool, reduceMotion: Bool) {
        fieldTint = tint
        self.isActive = isActive
        self.reduceMotion = reduceMotion
        updateCellColors()
        updateAnimations()
    }

    func stopAnimating() {
        cells.forEach { $0.removeAnimation(forKey: Self.animationKey) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let fieldSize = min(bounds.width, bounds.height)
        let cellSize = fieldSize / CGFloat(Self.sideLength)
        let origin = CGPoint(
            x: (bounds.width - fieldSize) / 2,
            y: (bounds.height - fieldSize) / 2
        )
        let gap = max(0.45, min(2.2, cellSize * 0.12))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, cell) in cells.enumerated() {
            let column = index % Self.sideLength
            let row = index / Self.sideLength
            cell.frame = CGRect(
                x: origin.x + CGFloat(column) * cellSize + gap / 2,
                y: origin.y + CGFloat(row) * cellSize + gap / 2,
                width: cellSize - gap,
                height: cellSize - gap
            )
            cell.cornerRadius = max(0.5, (cellSize - gap) * 0.24)
        }
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAnimations()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateCellColors()
    }

    private func updateCellColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let color = fieldTint.resolvedColor(with: traitCollection).cgColor
        cells.forEach { $0.backgroundColor = color }
        CATransaction.commit()
    }

    private func updateAnimations() {
        guard isActive, !reduceMotion, window != nil else {
            applyStaticGeneration()
            return
        }
        guard cells.first?.animation(forKey: Self.animationKey) == nil else { return }

        let startTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, cell) in cells.enumerated() {
            cell.opacity = Self.opacityValues[index][0].floatValue
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = Self.opacityValues[index]
            animation.timingFunctions = Self.timingFunctions
            animation.duration = Double(Self.animationGenerationCount) * Self.generationDuration
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            animation.beginTime = startTime
            cell.add(animation, forKey: Self.animationKey)
        }
        CATransaction.commit()
    }

    private func applyStaticGeneration() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, cell) in cells.enumerated() {
            cell.removeAnimation(forKey: Self.animationKey)
            cell.opacity = Self.opacityValues[index][0].floatValue
        }
        CATransaction.commit()
    }

    private static func nextGeneration(after generation: Set<Cell>) -> Set<Cell> {
        var neighborCounts: [Cell: Int] = [:]

        for cell in generation {
            for yOffset in -1...1 {
                for xOffset in -1...1 where xOffset != 0 || yOffset != 0 {
                    let neighbor = Cell(
                        x: wrapped(cell.x + xOffset),
                        y: wrapped(cell.y + yOffset)
                    )
                    neighborCounts[neighbor, default: 0] += 1
                }
            }
        }

        return Set(neighborCounts.compactMap { cell, count in
            count == 2 && !generation.contains(cell) ? cell : nil
        })
    }

    private static func expanded(_ cells: Set<Cell>, radius: Int) -> Set<Cell> {
        var expandedCells: Set<Cell> = []

        for cell in cells {
            for yOffset in -radius...radius {
                for xOffset in -radius...radius {
                    expandedCells.insert(
                        Cell(
                            x: wrapped(cell.x + xOffset),
                            y: wrapped(cell.y + yOffset)
                        )
                    )
                }
            }
        }

        return expandedCells
    }

    private static func wrapped(_ coordinate: Int) -> Int {
        (coordinate + sideLength) % sideLength
    }
}

private struct ProxyDisclosureDiagram: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "person.fill")
            Image(systemName: "arrow.right")
            Image("OxIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            Image(systemName: "arrow.right")
            Image(systemName: "globe")
        }
        .font(Theme.Icons.lg)
        .foregroundStyle(Theme.Colors.onSurface)
        .frame(maxWidth: .infinity, minHeight: 92)
        .accessibilityHidden(true)
    }
}

private struct OnboardingCommunityLinks: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.xl) {
            Link(destination: OxLinks.discord) {
                Label {
                    Text("Discord")
                } icon: {
                    Image("DiscordIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                }
            }
            .frame(minHeight: Theme.Size.minimumTouchTarget)
            .contentShape(Rectangle())
            .accessibilityIdentifier(A11yID.Onboarding.discord)

            Link(destination: OxLinks.github) {
                Label {
                    Text("GitHub")
                } icon: {
                    Image("GitHubIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                }
            }
            .frame(minHeight: Theme.Size.minimumTouchTarget)
            .contentShape(Rectangle())
            .accessibilityIdentifier(A11yID.Onboarding.github)
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(Theme.Colors.onSurfaceMuted)
    }
}

private struct WebsitesDemo: View {
    private struct Website {
        let title: String
        let domain: String
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ServiceManager.self) private var manager
    let height: CGFloat

    private let websites = [
        Website(title: "Google", domain: "google.com"),
        Website(title: "Amazon", domain: "amazon.com"),
        Website(title: "Airbnb", domain: "www.airbnb.com"),
        Website(title: "Instagram", domain: "instagram.com"),
        Website(title: "GitHub", domain: "github.com"),
        Website(title: "Gmail", domain: "mail.google.com"),
        Website(title: "LinkedIn", domain: "linkedin.com"),
        Website(title: "Wikipedia", domain: "en.wikipedia.org"),
        Website(title: "X", domain: "x.com"),
        Website(title: "Perplexity", domain: "www.perplexity.ai"),
        Website(title: "Apple Developer", domain: "developer.apple.com"),
        Website(title: "App Store Connect", domain: "appstoreconnect.apple.com"),
        Website(title: "Chase Travel", domain: "chase.com"),
        Website(title: "Bank of America", domain: "secure.bankofamerica.com"),
        Website(title: "American Express", domain: "americanexpress.com"),
        Website(title: "Hacker News", domain: "news.ycombinator.com"),
        Website(title: "FlightAware", domain: "www.flightaware.com"),
        Website(title: "USCIS", domain: "www.uscis.gov"),
        Website(title: "DoorDash", domain: "www.doordash.com"),
        Website(title: "Facebook", domain: "www.facebook.com")
    ]

    private var repeatedWebsites: [Website] { websites + websites + websites }
    private var gridSize: CGFloat {
        height
    }
    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(iconSize), spacing: Theme.Spacing.sm),
            count: 4
        )
    }
    private var iconSize: CGFloat {
        (gridSize - Theme.Spacing.sm * 3) / 4
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVGrid(columns: columns, spacing: Theme.Spacing.sm) {
                    ForEach(Array(repeatedWebsites.enumerated()), id: \.offset) { index, website in
                        WebsiteDemoIcon(title: website.title, domain: website.domain, size: iconSize)
                            .id(index)
                    }
                }
            }
            .scrollDisabled(true)
            .scrollIndicators(.hidden)
            .frame(width: gridSize, height: gridSize)
            .clipped()
            .task {
                var position = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1.4))
                    guard !Task.isCancelled else { return }
                    position += 4
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) {
                        proxy.scrollTo(position, anchor: .top)
                    }
                    if position == websites.count {
                        try? await Task.sleep(for: .seconds(0.5))
                        guard !Task.isCancelled else { return }
                        position = 0
                        proxy.scrollTo(position, anchor: .top)
                    }
                }
            }
        }
        .frame(width: height, height: height)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: websites.map(\.domain).joined(separator: ", ")))
        .accessibilityIdentifier(A11yID.Onboarding.websitesDemo)
        .task {
            if manager.services.isEmpty {
                let locale = AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
                await manager.refreshServices(locale: locale)
            }
        }
    }
}

private struct WebsiteDemoIcon: View {
    let title: String
    let domain: String
    let size: CGFloat
    @Environment(ServiceManager.self) private var manager

    private var service: Service? {
        manager.services.first { $0.domain == domain }
    }

    var body: some View {
        Group {
            if let service {
                ServiceAvatar(
                    service: service,
                    size: size,
                    shape: .roundedRect(Theme.Radius.md),
                    monogramSize: 13
                )
            } else {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(Theme.Colors.primary.opacity(0.12))
                    .frame(width: size, height: size)
                    .overlay {
                        Text(verbatim: String(title.prefix(1)))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.Colors.primary)
                    }
            }
        }
        .frame(maxWidth: .infinity)
    }
}


private struct OnboardingCTAButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.labelMd)
            .foregroundStyle(Theme.Colors.onPrimary)
            .padding(.vertical, 10)
            .padding(.horizontal, Theme.Spacing.xl)
            .frame(minHeight: 44)
            .background(
                (configuration.isPressed ? Theme.Colors.primaryPressed : Theme.Colors.primary),
                in: Capsule(style: .continuous)
            )
            .opacity(isEnabled ? 1 : 0.35)
    }
}

private struct ApprovalDemo: View {
    @State private var answer: String?

    private var options: [String] {
        [L10n.string("Approve"), L10n.string("Always approve"), L10n.string("Deny")]
    }
    private var prompt: String { L10n.string("Allow \("Amazon: Place order")?") }

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            if let answer {
                Text("You replied: \(answer)")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .padding(.vertical, 2)
            } else {
                Text(prompt)
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                PermissionActionButtons(options: options, onSelect: resolve)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity)
        .background {
            Color.clear.glassEffect(
                .regular.tint(Theme.Colors.surface.dynamic),
                in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
            )
        }
    }

    private func resolve(_ opt: String) {
        Haptics.impact(.selectionConfirmed)
        withAnimation(.easeOut(duration: 0.25)) { answer = opt }
    }
}

private struct ProviderPickerButton: View {
    let onPick: (String, String) -> Void
    @State private var showPicker = false

    private var registry: LLMRegistry { .shared }

    var body: some View {
        Button { showPicker = true } label: {
            Text("Choose your model")
        }
        .buttonStyle(OnboardingCTAButton())
        .accessibilityIdentifier(A11yID.Onboarding.chooseAI)
        .sheet(isPresented: $showPicker) {
            NavigationStack {
                ModelPickerContent(
                    title: L10n.string("Choose your model"),
                    activeClientID: registry.defaultClient,
                    activeModelID: registry.selected(for: registry.defaultClient).id
                ) { client, model in
                    Log.ui.info("Onboarding.pick client=\(client.id) model=\(model.id)")
                    registry.select(model, in: client.id)
                    onPick(client.displayName, model.displayName)
                    showPicker = false
                }
            }
            .presentationBackground(Theme.Colors.background)
            .environment(\.locale, AppLocale.shared.locale)
        }
    }
}
