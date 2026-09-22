import QuartzCore
import SwiftUI
import UIKit

struct OnboardingView: View {
    let onDone: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    OnboardingCellularField(isActive: true)
                        .frame(height: dynamicTypeSize.isAccessibilitySize ? 80 : 112)
                        .accessibilityHidden(true)

                    Text("A few things to know")
                        .font(Theme.Fonts.display)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.Colors.onSurface)
                        .padding(.top, Theme.Spacing.lg)

                    VStack(spacing: Theme.Spacing.xxl) {
                        OnboardingDisclosureRow(
                            symbol: "hammer",
                            title: "Intelligent proxy",
                            description: "Ox uses websites and apps on your behalf, freeing you from attention-hungry interfaces and slow legacy services. It turns what it learns into reusable capabilities, making future interactions faster and more reliable."
                        )
                        OnboardingDisclosureRow(
                            symbol: "chevron.left.forwardslash.chevron.right",
                            title: "Free software",
                            description: "Ox is completely free and open source. You can use any model provider while keeping all your data on device."
                        )
                        OnboardingDisclosureRow(
                            symbol: "hand.raised",
                            title: "Guaranteed safety",
                            description: "Ox asks before taking any sensitive actions, keeps your credentials isolated and lets you pull the plug any time."
                        )
                    }
                    .padding(.top, Theme.Spacing.xxl)

                    Spacer(minLength: Theme.Spacing.xxl)

                    VStack(spacing: Theme.Spacing.lg) {
                        Text("Ox can make mistakes when acting on your behalf. Review its work and grant permissions carefully.")
                            .font(Theme.Fonts.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                            .fixedSize(horizontal: false, vertical: true)

                        Button {
                            Log.ui.info("Onboarding.done")
                            onDone()
                        } label: {
                            Text("Get started")
                        }
                        .buttonStyle(OnboardingCTAButton())
                        .accessibilityIdentifier(A11yID.Onboarding.complete)
                    }
                    .padding(.top, Theme.Spacing.xxl)
                }
                .frame(maxWidth: 560)
                .frame(
                    minHeight: max(0, geometry.size.height - Theme.Spacing.xxl),
                    alignment: .top
                )
                .padding(.horizontal, Theme.Spacing.xxl)
                .padding(.vertical, Theme.Spacing.lg)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
        }
        .background(Theme.Colors.surface, ignoresSafeAreaEdges: .all)
        .environment(\.locale, AppLocale.shared.locale)
    }
}

private struct OnboardingDisclosureRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let description: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            Image(systemName: symbol)
                .font(Theme.Icons.lg)
                .foregroundStyle(Theme.Colors.onSurface)
                .frame(width: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(Theme.Fonts.title)
                    .foregroundStyle(Theme.Colors.onSurface)
                Text(description)
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
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
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in
            self.updateCellColors()
        }
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

private struct OnboardingCTAButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.labelMd)
            .foregroundStyle(Theme.Colors.onPrimary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                configuration.isPressed ? Theme.Colors.primaryPressed : Theme.Colors.primary,
                in: Capsule(style: .continuous)
            )
    }
}
