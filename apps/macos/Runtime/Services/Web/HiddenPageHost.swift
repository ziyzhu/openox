import AppKit
import SwiftUI
import WebKit

enum HiddenPageHost {
    static func keep(_ page: WebPage) -> () -> Void {
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let window = NSWindow(contentRect: NSRect(x: frame.minX, y: frame.minY, width: 1024, height: 768),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        window.contentView = NSHostingView(rootView: WebView(page))
        window.orderFrontRegardless()
        Log.webView.info("HiddenPageHost.keep mounted")
        return {
            window.orderOut(nil)
            window.contentView = nil
            Log.webView.info("HiddenPageHost.keep released")
        }
    }
}
