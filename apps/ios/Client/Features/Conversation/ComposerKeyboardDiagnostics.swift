import SwiftUI
import UIKit
import WebKit

struct ConversationWebInputFocus: UIViewRepresentable {
    @Binding var isFocused: Bool

    func makeUIView(context: Context) -> ProbeView {
        ProbeView()
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.onFocusChange = { isFocused = $0 }
    }

    final class ProbeView: UIView {
        var onFocusChange: ((Bool) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: name, object: nil)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardHidden), name: UIResponder.keyboardDidHideNotification, object: nil)
        }

        required init?(coder: NSCoder) {
            fatalError()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func keyboardHidden(_ notification: Notification) {
            guard let window, (notification.object as? UIScreen ?? window.screen) === window.screen else { return }
            onFocusChange?(false)
        }

        @objc private func keyboardChanged(_ notification: Notification) {
            guard let window,
                  (notification.object as? UIScreen ?? window.screen) === window.screen,
                  let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
            let keyboard = window.screen.coordinateSpace.convert(frame, to: window)
            onFocusChange?(window.bounds.intersects(keyboard) && hasFocusedWebInput(in: window))
        }

        private func hasFocusedWebInput(in view: UIView, insideWebView: Bool = false) -> Bool {
            let insideWebView = insideWebView || view is WKWebView
            if view.isFirstResponder && insideWebView { return true }
            return view.subviews.contains { hasFocusedWebInput(in: $0, insideWebView: insideWebView) }
        }
    }
}

struct ComposerKeyboardDiagnostics: UIViewRepresentable {
    let conversationID: UUID

    func makeUIView(context: Context) -> ProbeView {
        ProbeView()
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.conversationID = conversationID
    }

    final class ProbeView: UIView {
        var conversationID: UUID?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            for name in [
                UIResponder.keyboardWillChangeFrameNotification,
                UIResponder.keyboardDidChangeFrameNotification
            ] {
                NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: name, object: nil)
            }
        }

        required init?(coder: NSCoder) {
            fatalError()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func keyboardChanged(_ notification: Notification) {
            guard let window, let conversationID,
                  let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
            let screen = notification.object as? UIScreen ?? window.screen
            guard screen === window.screen else { return }
            let keyboard = screen.coordinateSpace.convert(frame, to: window)
            let composer = convert(bounds, to: window)
            let intersection = composer.intersection(keyboard).intersection(window.bounds)
            let overlap = intersection.isNull ? 0 : intersection.height
            let phase = notification.name == UIResponder.keyboardWillChangeFrameNotification ? "willChange" : "didChange"
            Log.ui.info("ConversationUX.keyboard conversation=\(conversationID) phase=\(phase) composer=\(composer) keyboard=\(keyboard) overlap=\(Int(overlap.rounded()))")
        }
    }
}
