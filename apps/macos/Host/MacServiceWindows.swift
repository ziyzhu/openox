import AppKit
import SwiftUI
import WebKit

@MainActor
final class MacServiceWindows: NSObject, NSWindowDelegate {
    struct Selection {
        let service: Service
        let session: Service.ServiceWebPage
    }

    private var windows: [UUID: NSWindow] = [:]

    func open(_ selection: Selection) {
        let id = selection.session.id
        guard selection.service.owns(selection.session) else {
            Log.ui.warning("MacHost page presentation rejected stale session=\(id)")
            return
        }
        if let window = windows[id] {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate()
            return
        }
        let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1064, height: 796)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: min(1000, available.width - 64), height: min(700, available.height - 96)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(selection.service.title) — Ox Host"
        window.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        window.minSize = NSSize(width: 640, height: 400)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: ServicePageView(selection: selection))
        windows[id] = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
        Log.ui.info("MacHost page presented domain=\(selection.service.domain) session=\(id)")
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let identifier = window.identifier,
              let id = UUID(uuidString: identifier.rawValue) else { return }
        window.contentView = nil
        windows.removeValue(forKey: id)
        Log.ui.info("MacHost page presentation detached session=\(id)")
    }
}

private struct ServicePageView: View {
    let selection: MacServiceWindows.Selection

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let owned = selection.service.owns(selection.session)
            let busy = selection.service.manager.actionScheduler.activeInvocationCount(on: selection.session) > 0
            let interactive = owned && selection.session.isReady && !busy
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selection.service.title).font(.headline)
                        Text(selection.session.page.url?.absoluteString ?? "Loading…")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(busy ? "Agent running — interaction paused" : selection.session.isReady ? "Live service page" : "Page not ready")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
                Divider()
                if owned {
                    WebView(selection.session.page)
                        .webViewTextSelection(.enabled)
                        .allowsHitTesting(interactive)
                        .disabled(!interactive)
                        .accessibilityIdentifier("mac-host-service-page")
                } else {
                    ContentUnavailableView("Service page ended", systemImage: "globe", description: Text("Choose another active page from the Ox Host menu."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}
