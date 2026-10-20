import SwiftUI
import UIKit

struct HoldToTalkArea: UIViewRepresentable {
    let canBegin: Bool
    let onTouchDown: () -> Void
    let onTap: () -> Void
    let onBegin: () -> Void
    let onMove: (CGPoint, CGFloat) -> Void
    let onRelease: () -> Void
    let onCancel: () -> Void

    func makeUIView(context: Context) -> Probe {
        Probe()
    }

    func updateUIView(_ view: Probe, context: Context) {
        view.canBegin = canBegin
        view.onTouchDown = onTouchDown
        view.onTap = onTap
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
        var onTouchDown: (() -> Void)?
        var onTap: (() -> Void)?
        var onBegin: (() -> Void)?
        var onMove: ((CGPoint, CGFloat) -> Void)?
        var onRelease: (() -> Void)?
        var onCancel: (() -> Void)?
        private var origin = CGPoint.zero
        private lazy var hold = UILongPressGestureRecognizer(target: self, action: #selector(holdChanged(_:)))
        private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapRecognized(_:)))

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            hold.minimumPressDuration = 0.35
            hold.allowableMovement = Theme.Size.minimumTouchTarget
            hold.delegate = self
            tap.delegate = self
            tap.require(toFail: hold)
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard hold.view !== window else { return }
            detach()
            guard let window else { return }
            window.addGestureRecognizer(hold)
            window.addGestureRecognizer(tap)
        }

        func detach() {
            hold.view?.removeGestureRecognizer(hold)
            tap.view?.removeGestureRecognizer(tap)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard canBegin, window != nil, bounds.contains(touch.location(in: self)),
                  let controller = owningViewController, let touchedView = touch.view else { return false }
            let receivesTouch = touchedView.isDescendant(of: controller.view)
            if receivesTouch, gestureRecognizer === hold { onTouchDown?() }
            return receivesTouch
        }

        private var owningViewController: UIViewController? {
            var responder: UIResponder? = next
            while let current = responder {
                if let controller = current as? UIViewController { return controller }
                responder = current.next
            }
            return nil
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

        @objc private func tapRecognized(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            onTap?()
        }
    }
}

struct HoldToTalkWaveform: View {
    let speech: ConversationSpeechInput
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color {
        (speech.selection == .cancel ? Theme.Colors.error : Theme.Colors.primary).color(for: colorScheme)
    }

    private var status: LocalizedStringKey {
        switch speech.state {
        case .idle: ""
        case .preparing, .starting: "Preparing speech…"
        case .finalizing: "Transcribing and sending…"
        case .recording(.cancel): "Release to cancel"
        case .recording(.send): "Release to send"
        }
    }

    var body: some View {
        Group {
            if speech.isRecording {
                TimelineView(.animation(minimumInterval: 0.05, paused: reduceMotion)) { context in
                    waveform(at: context.date)
                }
            } else {
                CellularAutomatonLoader(size: 20, tint: accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 22)
        .accessibilityElement()
        .accessibilityLabel(status)
        .accessibilityIdentifier(A11yID.ConversationControls.speechStatus)
        .accessibilityAction(named: Text("Stop and send")) { speech.release(action: .send) }
        .accessibilityAction(named: Text("Cancel")) { speech.cancel(reason: "accessibilityCancel") }
        .accessibilityAction(.escape) { speech.cancel(reason: "accessibilityEscape") }
        .onAppear {
            if speech.usesAccessibleControls {
                UIAccessibility.post(notification: .screenChanged, argument: nil)
            }
        }
    }
    private func waveform(at date: Date) -> some View {
        Canvas { context, size in
            let time = date.timeIntervalSinceReferenceDate
            let cell: CGFloat = 3
            let columns = max(Int(size.width / 6), 2)
            let spacing = (size.width - cell) / CGFloat(columns - 1)
            for column in 0..<columns {
                let envelope = 0.35 + 0.65 * sin(Double(column) / Double(columns - 1) * .pi)
                let variation = reduceMotion ? 0.8 : 0.5 + 0.5 * abs(sin(time * 4 + Double(column) * 0.55))
                let height = Int((sqrt(Double(speech.level)) * envelope * variation * 2).rounded())
                for row in -2...2 {
                    let rect = CGRect(x: CGFloat(column) * spacing, y: size.height / 2 + CGFloat(row) * 4.5 - cell / 2, width: cell, height: cell)
                    let opacity = abs(row) <= height ? 1.0 : 0.12
                    context.fill(Path(roundedRect: rect, cornerRadius: 0.75), with: .color(accent.opacity(opacity)))
                }
            }
        }
    }
}
