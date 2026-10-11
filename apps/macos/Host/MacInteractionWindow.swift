import AppKit
import SwiftUI

@MainActor
final class MacInteractionWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    private var onClose: (() -> Void)?

    init<V: View>(title: String, size: NSSize = NSSize(width: 1000, height: 700), view: V, onClose: @escaping () -> Void) {
        let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1064, height: 796)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: min(size.width, available.width - 64), height: min(size.height, available.height - 96)),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        self.onClose = onClose
        super.init()
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    func dismiss() {
        onClose = nil
        window.close()
        window.contentView = nil
    }

    func windowWillClose(_ notification: Notification) {
        let close = onClose
        onClose = nil
        close?()
    }
}

@MainActor
enum MacCredentialPrompt {
    static func choose(title: String, message: String, buttons: [String]) async throws -> Int {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        for (index, title) in buttons.enumerated() {
            alert.addButton(withTitle: title).setAccessibilityIdentifier("mac-host-auth-choice-\(index)")
        }
        let owner = MacInteractionWindow(title: title, size: NSSize(width: 440, height: 180), view: Text(message).padding(24)) { NSApplication.shared.endSheet(alert.window, returnCode: NSApplication.ModalResponse.abort.rawValue) }
        defer { owner.dismiss() }
        let response = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: NSApplication.ModalResponse.abort) }
                else { alert.beginSheetModal(for: owner.window) { continuation.resume(returning: $0) } }
            }
        } onCancel: {
            Task { @MainActor in NSApplication.shared.endSheet(alert.window, returnCode: NSApplication.ModalResponse.abort.rawValue) }
        }
        try Task.checkCancellation()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard buttons.indices.contains(index) else { throw CancellationError() }
        return index
    }

    static func enter(title: String, username: Bool = false, message: String = "Enter credentials on this Host. They are stored securely and are not sent to the conversation.") async throws -> (secret: String, username: String?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Save").setAccessibilityIdentifier("mac-host-credentials-save")
        alert.addButton(withTitle: "Cancel").setAccessibilityIdentifier("mac-host-credentials-cancel")
        let secret = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        secret.placeholderString = "Secret"
        secret.setAccessibilityIdentifier("mac-host-credentials-secret")
        let name = NSTextField(frame: NSRect(x: 0, y: 36, width: 320, height: 24))
        name.placeholderString = "Username"
        name.setAccessibilityIdentifier("mac-host-credentials-username")
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: username ? 60 : 24))
        fields.addSubview(secret)
        if username { fields.addSubview(name) }
        alert.accessoryView = fields
        let owner = MacInteractionWindow(title: title, size: NSSize(width: 440, height: 180), view: Text("Authentication stays on this Host.").padding(24)) { NSApplication.shared.endSheet(alert.window, returnCode: NSApplication.ModalResponse.abort.rawValue) }
        defer {
            secret.stringValue = ""
            name.stringValue = ""
            owner.dismiss()
        }
        let response = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: NSApplication.ModalResponse.abort) }
                else { alert.beginSheetModal(for: owner.window) { continuation.resume(returning: $0) } }
            }
        } onCancel: {
            Task { @MainActor in NSApplication.shared.endSheet(alert.window, returnCode: NSApplication.ModalResponse.abort.rawValue) }
        }
        try Task.checkCancellation()
        guard response == .alertFirstButtonReturn else { throw CancellationError() }
        guard !secret.stringValue.isEmpty, !secret.stringValue.contains("\r"), !secret.stringValue.contains("\n"),
              !name.stringValue.contains(":"), !name.stringValue.contains("\r"), !name.stringValue.contains("\n") else {
            throw APIServiceError.invalidRequest
        }
        return (secret.stringValue, username ? name.stringValue : nil)
    }
}
