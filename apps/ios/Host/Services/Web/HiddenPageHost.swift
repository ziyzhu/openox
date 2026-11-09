import SwiftUI
import UIKit
import WebKit

enum HiddenPageHost {
    static func keep(_ page: WebPage) -> () -> Void {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else {
            Log.webView.warning("HiddenPageHost.keep unavailable reason=no-window")
            return {}
        }
        let host = UIHostingController(rootView: WebView(page))
        host.view.frame = window.bounds
        host.view.alpha = 0.01
        host.view.isUserInteractionEnabled = false
        host.view.accessibilityElementsHidden = true
        window.insertSubview(host.view, at: 0)
        Log.webView.info("HiddenPageHost.keep mounted")
        return {
            host.view.removeFromSuperview()
            Log.webView.info("HiddenPageHost.keep released")
        }
    }
}
