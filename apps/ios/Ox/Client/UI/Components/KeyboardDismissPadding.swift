import SwiftUI
import UIKit

struct KeyboardDismissPadding: UIViewRepresentable {
    var padding: CGFloat

    func makeUIView(context: Context) -> ProbeView {
        ProbeView()
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.padding = padding
        DispatchQueue.main.async { view.apply() }
    }

    final class ProbeView: UIView {
        var padding: CGFloat = 0

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

        func apply() {
            var node = superview
            while let current = node {
                if let scroll = current as? UIScrollView {
                    guard scroll.keyboardLayoutGuide.keyboardDismissPadding != padding else { return }
                    scroll.keyboardLayoutGuide.keyboardDismissPadding = padding
                    Log.ui.debug("KeyboardDismissPadding.apply padding=\(Int(self.padding)) scroll=\(type(of: scroll))")
                    return
                }
                node = current.superview
            }
        }
    }
}
