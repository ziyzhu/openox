import SwiftUI
import UIKit

struct ImmediateScrollTouches: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView {
        ProbeView()
    }

    func updateUIView(_ view: ProbeView, context: Context) {}

    final class ProbeView: UIView {
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

        private func apply() {
            var node = superview
            while let current = node {
                if let scroll = current as? UIScrollView {
                    guard scroll.delaysContentTouches else { return }
                    scroll.delaysContentTouches = false
                    Log.ui.debug("ImmediateScrollTouches.apply scroll=\(type(of: scroll))")
                    return
                }
                node = current.superview
            }
        }
    }
}
