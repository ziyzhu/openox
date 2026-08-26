import SwiftUI
import UIKit

struct HoldToTalkArea: UIViewRepresentable {
    let canBegin: Bool
    let onBegin: () -> Void
    let onMove: (CGPoint, CGFloat) -> Void
    let onRelease: () -> Void
    let onCancel: () -> Void

    func makeUIView(context: Context) -> Probe {
        Probe()
    }

    func updateUIView(_ view: Probe, context: Context) {
        view.canBegin = canBegin
        view.onBegin = onBegin
        view.onMove = onMove
        view.onRelease = onRelease
        view.onCancel = onCancel
    }

    static func dismantleUIView(_ view: Probe, coordinator: ()) {
        view.detach()
    }

    final class Probe: UIView, UIGestureRecognizerDelegate {
        var canBegin = true
        var onBegin: (() -> Void)?
        var onMove: ((CGPoint, CGFloat) -> Void)?
        var onRelease: (() -> Void)?
        var onCancel: (() -> Void)?
        private var origin = CGPoint.zero
        private lazy var hold = UILongPressGestureRecognizer(target: self, action: #selector(holdChanged(_:)))

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            hold.minimumPressDuration = 0.35
            hold.delegate = self
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            window?.addGestureRecognizer(hold)
        }

        func detach() {
            hold.view?.removeGestureRecognizer(hold)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard canBegin, window != nil, bounds.contains(touch.location(in: self)) else { return false }
            var view = touch.view
            while let candidate = view {
                if candidate.accessibilityIdentifier == A11yID.Chat.input { return true }
                view = candidate.superview
            }
            return false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc private func holdChanged(_ gesture: UILongPressGestureRecognizer) {
            let point = gesture.location(in: window)
            switch gesture.state {
            case .began:
                origin = point
                onBegin?()
            case .changed:
                onMove?(point, hypot(point.x - origin.x, point.y - origin.y))
            case .ended:
                onMove?(point, hypot(point.x - origin.x, point.y - origin.y))
                onRelease?()
            case .cancelled: onCancel?()
            default: break
            }
        }
    }
}

struct HoldToTalkOverlay: View {
    let speech: ChatSpeechInput
    @Environment(\.appTheme) private var appTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var accent: Color {
        (speech.selection == .cancel ? Theme.Colors.error : Theme.Colors.primary).color(for: appTheme)
    }

    private var instruction: LocalizedStringKey {
        switch speech.state {
        case .idle: ""
        case .preparing, .starting: "Preparing speech…"
        case .finalizing(.edit): "Transcribing…"
        case .finalizing: "Transcribing and sending…"
        case .recording(.cancel): "Release to cancel"
        case .recording(.edit): "Release to edit text"
        case .recording(.send): "Release to send"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Theme.Colors.chatSurface.color(for: appTheme).opacity(0.6)
                    .contentShape(Rectangle())
                LinearGradient(
                    colors: [.clear, Theme.Colors.background.color(for: appTheme)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                recordingCard
                    .frame(maxWidth: 480)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.bottom, geometry.safeAreaInsets.bottom + Theme.Size.minimumTouchTarget + Theme.Spacing.lg)
                    .frame(maxWidth: .infinity)
            }
        }
        .ignoresSafeArea()
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { speech.cancel(reason: "accessibilityEscape") }
        .onAppear {
            if speech.usesAccessibleControls {
                UIAccessibility.post(notification: .screenChanged, argument: nil)
            }
        }
    }

    private var recordingCard: some View {
        VStack(spacing: Theme.Spacing.xl) {
            VStack(spacing: Theme.Spacing.md) {
                feedback
                    .frame(height: 48)
                    .padding(.bottom, Theme.Spacing.xs)
                    .accessibilityHidden(true)
                Text(instruction)
                    .font(Theme.Fonts.headline)
                    .foregroundStyle(speech.selection == .cancel ? Theme.Colors.error : Theme.Colors.onSurface)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier(A11yID.Chat.speechStatus)
                    .accessibilityAction(named: Text("Stop and send")) { speech.release(action: .send) }
            }
            HStack(spacing: Theme.Spacing.md) {
                target(.cancel, title: "Cancel", symbol: "xmark")
                target(.edit, title: "Edit text", symbol: "text.cursor")
            }
        }
        .padding(Theme.Spacing.xl)
        .background {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
            if reduceTransparency {
                shape.fill(Theme.Colors.surface)
            } else {
                shape.fill(Theme.Colors.surface.opacity(0.84))
                    .glassEffect(.regular, in: shape)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                .strokeBorder(Theme.Colors.onSurface.opacity(0.06), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(appTheme == .dark ? 0.2 : 0.06), radius: 24, y: 8)
    }

    @ViewBuilder
    private var feedback: some View {
        if speech.isRecording {
            TimelineView(.animation(minimumInterval: 0.05, paused: reduceMotion)) { context in
                waveform(at: context.date)
            }
            .frame(width: 190)
        } else {
            CellularAutomatonLoader(size: 32, tint: accent)
        }
    }

    private func waveform(at date: Date) -> some View {
        Canvas { context, size in
            let time = date.timeIntervalSinceReferenceDate
            let cell: CGFloat = 4
            let spacing = (size.width - cell) / 26
            for column in 0..<27 {
                let envelope = 0.35 + 0.65 * sin(Double(column) / 26 * .pi)
                let variation = reduceMotion ? 0.8 : 0.5 + 0.5 * abs(sin(time * 4 + Double(column) * 0.55))
                let height = Int((sqrt(Double(speech.level)) * envelope * variation * 3).rounded())
                for row in -3...3 {
                    let rect = CGRect(x: CGFloat(column) * spacing, y: size.height / 2 + CGFloat(row) * 6 - cell / 2, width: cell, height: cell)
                    let opacity = abs(row) <= height ? 1.0 : 0.1
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(accent.opacity(opacity)))
                }
            }
        }
    }

    private func target(_ action: ChatSpeechInput.ReleaseAction, title: LocalizedStringKey, symbol: String) -> some View {
        let selected = speech.selection == action
        let color = (action == .cancel ? Theme.Colors.error : Theme.Colors.primary).color(for: appTheme)
        return Button {
            if action == .cancel { speech.cancel(reason: "cancelButton") }
            else { speech.release(action: action) }
        } label: {
            Label(title, systemImage: symbol)
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(selected ? color : Theme.Colors.onSurface.color(for: appTheme))
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(selected ? color.opacity(0.14) : Theme.Colors.surfaceSunken.color(for: appTheme), in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .strokeBorder(selected ? color.opacity(0.5) : .clear, lineWidth: 1.5)
                }
                .scaleEffect(selected ? 1.03 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: Theme.Animation.quick), value: selected)
        }
        .buttonStyle(.plain)
        .disabled(action == .edit && !speech.isRecording)
        .accessibilityIdentifier(action == .cancel ? A11yID.Chat.speechCancel : A11yID.Chat.speechEdit)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            if action == .cancel { speech.cancelFrame = frame }
            else { speech.editFrame = frame }
        }
    }
}
