import SwiftUI
import UIKit

struct KeyboardDismissPadding: UIViewRepresentable {
    var padding: CGFloat
    var onKeyboardFrameChange: ((CGRect?) -> Void)?

    init(padding: CGFloat, onKeyboardFrameChange: ((CGRect?) -> Void)? = nil) {
        self.padding = padding
        self.onKeyboardFrameChange = onKeyboardFrameChange
    }

    func makeUIView(context: Context) -> ProbeView {
        ProbeView()
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.padding = padding
        view.onKeyboardFrameChange = onKeyboardFrameChange
        DispatchQueue.main.async { view.apply() }
    }

    final class ProbeView: UIView {
        var padding: CGFloat = 0
        var onKeyboardFrameChange: ((CGRect?) -> Void)?
        private var pendingKeyboardFrame = CGRect.null
        private var keyboardFrameTask: Task<Void, Never>?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) {
            fatalError()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            DispatchQueue.main.async { self.apply() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            DispatchQueue.main.async { self.apply() }
        }

        func apply() {
            var node = superview
            while let current = node {
                if let scroll = current as? UIScrollView {
                    if scroll.keyboardLayoutGuide.keyboardDismissPadding != padding {
                        scroll.keyboardLayoutGuide.keyboardDismissPadding = padding
                        Log.ui.debug("KeyboardDismissPadding.apply padding=\(Int(self.padding)) scroll=\(type(of: scroll))")
                    }
                    reportKeyboardFrame(from: scroll)
                    return
                }
                node = current.superview
            }
        }

        private func reportKeyboardFrame(from scroll: UIScrollView) {
            guard let window, onKeyboardFrameChange != nil else { return }
            let frame = scroll.convert(scroll.keyboardLayoutGuide.layoutFrame, to: window)
            let isVisible = frame.height > window.safeAreaInsets.bottom + padding + 1
            let isDocked = abs(frame.maxY - window.bounds.maxY) <= 1
            let next = isVisible && isDocked ? frame : .null
            guard next != pendingKeyboardFrame else { return }
            pendingKeyboardFrame = next
            keyboardFrameTask?.cancel()
            keyboardFrameTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
                guard let self, self.pendingKeyboardFrame == next else { return }
                self.onKeyboardFrameChange?(next.isNull ? nil : next)
            }
        }
    }
}
