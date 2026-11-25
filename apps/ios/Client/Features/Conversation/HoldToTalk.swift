import SwiftUI
import UIKit

struct HoldToTalkArea: UIViewRepresentable {
    let canBegin: Bool
    let onPress: () -> Void
    let onMove: (CGPoint, CGFloat) -> Void
    let onLift: () -> Void
    let onCancel: () -> Void

    func makeUIView(context: Context) -> Probe {
        Probe()
    }

    func updateUIView(_ view: Probe, context: Context) {
        view.canBegin = canBegin
        view.onPress = onPress
        view.onMove = onMove
        view.onLift = onLift
        view.onCancel = onCancel
    }

    static func dismantleUIView(_ view: Probe, coordinator: ()) {
        view.detach()
    }

    final class Probe: UIView, UIGestureRecognizerDelegate {
        var canBegin = true
        var onPress: (() -> Void)?
        var onMove: ((CGPoint, CGFloat) -> Void)?
        var onLift: (() -> Void)?
        var onCancel: (() -> Void)?
        private var origin = CGPoint.zero
        private lazy var press = UILongPressGestureRecognizer(target: self, action: #selector(pressChanged(_:)))

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            press.minimumPressDuration = 0
            press.delegate = self
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard press.view !== window else { return }
            detach()
            window?.addGestureRecognizer(press)
        }

        func detach() {
            if press.state == .began || press.state == .changed, let onCancel {
                DispatchQueue.main.async(execute: onCancel)
            }
            press.view?.removeGestureRecognizer(press)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard canBegin, window != nil, bounds.contains(touch.location(in: self)),
                  let controller = owningViewController, let touchedView = touch.view else { return false }
            return touchedView.isDescendant(of: controller.view)
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

        @objc private func pressChanged(_ gesture: UILongPressGestureRecognizer) {
            let point = gesture.location(in: window)
            switch gesture.state {
            case .began:
                origin = point
                onPress?()
            case .changed:
                onMove?(point, hypot(point.x - origin.x, point.y - origin.y))
            case .ended:
                onMove?(point, hypot(point.x - origin.x, point.y - origin.y))
                onLift?()
            case .cancelled: onCancel?()
            default: break
            }
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
        .accessibilityLabel(speech.status)
        .accessibilityIdentifier(A11yID.ConversationControls.speechStatus)
        .accessibilityAction(named: Text("Stop and send")) { speech.finish() }
        .accessibilityAction(named: Text("Cancel")) { speech.cancel(reason: "accessibilityCancel") }
        .accessibilityAction(.escape) { speech.cancel(reason: "accessibilityEscape") }
        .onAppear {
            if speech.isHandsFree {
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

private extension ConversationSpeechInput {
    var status: LocalizedStringKey {
        switch (state, destination) {
        case (.idle, _): ""
        case (.preparing, _), (.starting, _): "Preparing speech…"
        case (.downloading(let percent), _): "Downloading speech model… \(percent)%"
        case (.finalizing, .send): "Transcribing and sending…"
        case (.finalizing, .draft): "Transcribing…"
        case (.recording(.hold(.cancel)), _): "Release to cancel"
        case (.recording(.hold(.send)), .send): "Release to send"
        case (.recording(.hold(.send)), .draft): "Release to add to draft"
        case (.recording(.tap), .send): "Tap to send"
        case (.recording(.tap), .draft): "Tap to add to draft"
        }
    }
}

struct HoldToTalkStatus: View {
    let speech: ConversationSpeechInput
    @Environment(\.colorScheme) private var colorScheme

    private var isCancelling: Bool { speech.selection == .cancel }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(speech.status)
                .foregroundStyle((isCancelling ? Theme.Colors.error : Theme.Colors.onSurface).color(for: colorScheme))
            if speech.state == .recording(.hold(.send)) {
                Text("Slide up to cancel", comment: "Hint shown next to Release to send while holding to talk.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(Theme.Fonts.captionMd)
        .lineLimit(1)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .glassEffect(
            isCancelling ? .regular.tint(Theme.Colors.error.color(for: colorScheme).opacity(0.18)) : .regular,
            in: Capsule()
        )
        .accessibilityHidden(true)
    }
}

struct HoldToTalkTranscript: View {
    let draft: String
    let separator: String
    let transcript: String
    @Environment(\.colorScheme) private var colorScheme

    private var text: AttributedString {
        var existing = AttributedString(draft)
        existing.foregroundColor = Theme.Colors.onSurfaceMuted.color(for: colorScheme)
        var spoken = AttributedString(separator + transcript)
        spoken.foregroundColor = Theme.Colors.onSurface.color(for: colorScheme)
        return existing + spoken
    }

    var body: some View {
        Text(text)
            .font(Theme.Fonts.bodyMd)
            .lineLimit(3)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(A11yID.ConversationControls.speechTranscript)
    }
}
