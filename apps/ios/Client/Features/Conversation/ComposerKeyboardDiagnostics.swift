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
        private var resyncedKeyboard: CGRect?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: name, object: nil)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardHidden), name: UIResponder.keyboardDidHideNotification, object: nil)
            // Focus can move from a web field to a native field without a keyboard frame change.
            for name in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(nativeInputBegan), name: name, object: nil)
            }
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

        @objc private func nativeInputBegan(_ notification: Notification) {
            guard let window, let input = notification.object as? UIView, input.window === window else { return }
            onFocusChange?(false)
        }

        @objc private func keyboardChanged(_ notification: Notification) {
            guard let window,
                  (notification.object as? UIScreen ?? window.screen) === window.screen,
                  let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
            let keyboard = window.screen.coordinateSpace.convert(frame, to: window)
            onFocusChange?(window.bounds.intersects(keyboard) && hasFocusedWebInput(in: window))
            if notification.name == UIResponder.keyboardDidChangeFrameNotification {
                resyncKeyboardGuide(keyboard: keyboard, in: window)
            }
        }

        private func resyncKeyboardGuide(keyboard: CGRect, in window: UIWindow) {
            guard window.bounds.intersects(keyboard),
                  let root = window.rootViewController?.view,
                  let responder = firstResponder(in: window) else { return }
            let guide = root.convert(root.keyboardLayoutGuide.layoutFrame, to: window)
            let drift = guide.minY - keyboard.minY
            guard abs(drift) > 1 else {
                resyncedKeyboard = nil
                return
            }
            guard resyncedKeyboard != keyboard else { return }
            resyncedKeyboard = keyboard
            Log.ui.warning("ConversationUX.keyboardGuide drift=\(Int(drift.rounded())) guide=\(guide) keyboard=\(keyboard) responder=\(type(of: responder)) action=reloadInputViews")
            responder.reloadInputViews()
        }

        private func firstResponder(in view: UIView) -> UIView? {
            if view.isFirstResponder { return view }
            return view.subviews.lazy.compactMap { self.firstResponder(in: $0) }.first
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
