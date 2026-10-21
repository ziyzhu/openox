import Foundation
import WebKit

extension Service.ServiceWebPage {
    final class NavigationDecider: WebPage.NavigationDeciding {
        weak var service: Service?
        weak var servicePage: Service.ServiceWebPage?

        init(service: Service) {
            self.service = service
        }

        func decidePolicy(
            for action: WebPage.NavigationAction,
            preferences: inout WebPage.NavigationPreferences
        ) async -> WKNavigationActionPolicy {
            guard let service, let servicePage else { return .cancel }
            return await service.decidePolicy(for: action, preferences: &preferences, in: servicePage)
        }

        func decidePolicy(for response: WebPage.NavigationResponse) async -> WKNavigationResponsePolicy {
            guard let service, let servicePage else { return .cancel }
            return await service.decidePolicy(for: response, in: servicePage)
        }
    }
}

extension Service {
    func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences,
        in session: ServiceWebPage
    ) async -> WKNavigationActionPolicy {
        let url = action.request.url
        if action.target?.isMainFrame == false {
            guard let frameURL = url, await BrowserNavigation.resolvesFrameNavigation(frameURL) else {
                Log.webView.error("Service.navigation rejected-frame domain=\(domain) url=\(LogPrivacy.url(url?.absoluteString ?? "?"))")
                return .cancel
            }
            return .allow
        }
        guard let pageURL = url, await BrowserNavigation.resolvesServiceNavigation(pageURL) else {
            let scheme = url?.scheme?.uppercased() ?? "unsupported"
            let failure = scheme == "HTTPS"
                ? "Browser blocked navigation to a private-network, unresolvable, or unsupported HTTPS destination"
                : "Browser blocked navigation to an unsupported \(scheme) destination; Browser only loads public HTTPS destinations"
            if owns(session) {
                session.navigationFailure = failure
            }
            Log.webView.error("Service.navigation rejected domain=\(domain) url=\(LogPrivacy.url(url?.absoluteString ?? "?"))")
            if owns(session), session.navigationPhase.load != nil {
                await receive(.failed(RuntimeError.bridge(failure)), from: session)
            }
            return .cancel
        }
        guard owns(session) else { return .cancel }
        configureScripts(for: url, in: session)
        if action.target == nil {
            Log.webView.info("Service.navigation popup-request domain=\(domain) session=\(session.logLabel) url=\(LogPrivacy.url(url?.absoluteString ?? "?"))")
            session.page.load(action.request)
            return .cancel
        }
        Log.webView.info("Service.navigation allowed domain=\(domain) session=\(session.logLabel) url=\(LogPrivacy.url(url?.absoluteString ?? "?"))")
        return .allow
    }

    func decidePolicy(for response: WebPage.NavigationResponse, in session: ServiceWebPage) async -> WKNavigationResponsePolicy {
        guard response.canShowMimeType else {
            if owns(session) {
                await receive(.becameDownload, from: session)
            }
            return .cancel
        }
        return .allow
    }
}
extension Service {
    nonisolated func isServiceHost(_ host: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }
}

extension Service: WKScriptMessageHandler {
    nonisolated func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            let frame = message.frameInfo
            let origin = frame.securityOrigin.host
            let tag = origin.isEmpty ? (frame.request.url?.host ?? "?") : origin
            guard isServiceHost(tag) else { return }
            WebViewBridges.handle(message: message, tag: tag)
        }
    }
}
