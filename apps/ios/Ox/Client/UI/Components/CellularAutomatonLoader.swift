import QuartzCore
import SwiftUI
import UIKit

struct CellularAutomatonLoader: View {
    var size: CGFloat = 28
    var tint: Color = Theme.Colors.primary.dynamic

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CellularAutomatonLoaderViewRepresentable(
            tint: UIColor(tint),
            reduceMotion: reduceMotion
        )
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }

    static var small: CellularAutomatonLoader { CellularAutomatonLoader(size: 16) }
    static var mini: CellularAutomatonLoader { CellularAutomatonLoader(size: 12) }
}

private struct CellularAutomatonLoaderViewRepresentable: UIViewRepresentable {
    let tint: UIColor
    let reduceMotion: Bool

    func makeUIView(context: Context) -> CellularAutomatonLoaderView {
        let view = CellularAutomatonLoaderView()
        view.configure(tint: tint, reduceMotion: reduceMotion)
        return view
    }

    func updateUIView(_ view: CellularAutomatonLoaderView, context: Context) {
        view.configure(tint: tint, reduceMotion: reduceMotion)
    }

    static func dismantleUIView(_ view: CellularAutomatonLoaderView, coordinator: Void) {
        view.stopAnimating()
    }
}

private final class CellularAutomatonLoaderView: UIView {
    private static let sideLength = 4
    private static let cellCount = sideLength * sideLength
    private static let ruleNumber = UInt32(75)
    private static let generationDuration = 0.15
    private static let iconGeneration = UInt32(0b0110_0110_1111_1001)
    private static let animationKey = "cellularAutomaton"
    private static let generations: [UInt32] = {
        var generations: [UInt32] = []
        var generation = iconGeneration

        repeat {
            generations.append(generation)
            generation = nextGeneration(after: generation)
        } while generation != iconGeneration

        return generations
    }()

    private let cells = (0..<cellCount).map { _ in CALayer() }
    private var loaderTint = UIColor.clear
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

    func configure(tint: UIColor, reduceMotion: Bool) {
        loaderTint = tint
        self.reduceMotion = reduceMotion
        updateCellColors()
        updateAnimations()
    }

    func stopAnimating() {
        cells.forEach { $0.removeAnimation(forKey: Self.animationKey) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let length = min(bounds.width, bounds.height)
        let gap = max(0.75, length * 0.055)
        let cellSize = (length - gap * CGFloat(Self.sideLength - 1)) / CGFloat(Self.sideLength)
        let gridOrigin = CGPoint(x: (bounds.width - length) / 2, y: (bounds.height - length) / 2)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for row in 0..<Self.sideLength {
            for column in 0..<Self.sideLength {
                let index = row * Self.sideLength + column
                cells[index].frame = CGRect(
                    x: gridOrigin.x + CGFloat(column) * (cellSize + gap),
                    y: gridOrigin.y + CGFloat(row) * (cellSize + gap),
                    width: cellSize,
                    height: cellSize
                )
                cells[index].cornerRadius = cellSize * 0.28
            }
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
        let color = loaderTint.resolvedColor(with: traitCollection).cgColor
        cells.forEach { $0.backgroundColor = color }
        CATransaction.commit()
    }

    private func updateAnimations() {
        guard !reduceMotion else {
            applyStaticGeneration()
            return
        }
        guard window != nil else { return }

        for (index, cell) in cells.enumerated() where cell.animation(forKey: Self.animationKey) == nil {
            cell.add(Self.animation(forCellAt: index, layer: cell), forKey: Self.animationKey)
        }
    }

    private func applyStaticGeneration() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, cell) in cells.enumerated() {
            cell.removeAnimation(forKey: Self.animationKey)
            let opacity: Float = Self.contains(Self.iconGeneration, index) ? 1 : 0.08
            cell.opacity = opacity
            let scale = 0.72 + CGFloat(opacity) * 0.28
            cell.transform = CATransform3DMakeScale(scale, scale, 1)
        }
        CATransaction.commit()
    }

    private static func animation(forCellAt index: Int, layer: CALayer) -> CAAnimationGroup {
        let generationCount = generations.count
        let opacities = (generations + [iconGeneration]).map {
            contains($0, index) ? CGFloat(1) : CGFloat(0.08)
        }
        let keyTimes = (0...generationCount).map {
            NSNumber(value: Double($0) / Double(generationCount))
        }
        let timingFunctions = (0..<generationCount).map { _ in
            CAMediaTimingFunction(name: .easeInEaseOut)
        }

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = opacities
        opacity.keyTimes = keyTimes
        opacity.timingFunctions = timingFunctions

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = opacities.map { 0.72 + $0 * 0.28 }
        scale.keyTimes = keyTimes
        scale.timingFunctions = timingFunctions

        let duration = Double(generationCount) * generationDuration
        let localTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        let animation = CAAnimationGroup()
        animation.animations = [opacity, scale]
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.beginTime = localTime - localTime.truncatingRemainder(dividingBy: duration)
        return animation
    }

    private static func nextGeneration(after generation: UInt32) -> UInt32 {
        var nextGeneration = UInt32(0)

        for index in 0..<cellCount {
            let left = (index - 1 + cellCount) % cellCount
            let right = (index + 1) % cellCount
            let neighborhood =
                (contains(generation, left) ? 4 : 0)
                | (contains(generation, index) ? 2 : 0)
                | (contains(generation, right) ? 1 : 0)
            if ruleNumber & (UInt32(1) << neighborhood) != 0 {
                nextGeneration |= UInt32(1) << index
            }
        }

        return nextGeneration
    }

    private static func contains(_ generation: UInt32, _ index: Int) -> Bool {
        generation & UInt32(1) << index != 0
    }
}

#Preview("Rule 75 cellular automaton loader") {
    VStack(spacing: Theme.Spacing.xl) {
        CellularAutomatonLoader(size: 132)

        HStack(spacing: Theme.Spacing.xxl) {
            CellularAutomatonLoader()
            CellularAutomatonLoader.small
            CellularAutomatonLoader.mini
        }
    }
    .padding(Theme.Spacing.xxl)
    .background(Theme.Colors.surface)
}
