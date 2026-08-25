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
        guard action.target?.isMainFrame != false else { return .allow }
        let url = action.request.url
        let allowed = url.map(ServiceHandoffSession.allowsNavigation) == true
        guard allowed else {
            Log.webView.error("Service.navigation rejected domain=\(domain) url=\(LogPrivacy.url(url?.absoluteString ?? "?"))")
            return .cancel
        }
        guard owns(session) else { return .cancel }
        configureScripts(for: url, in: session)
        if isSameDocumentNavigation(from: session.page.url, to: url) {
            Log.webView.info("Service.navigation event=route domain=\(domain) session=\(session.logLabel) url=\(LogPrivacy.url(url?.absoluteString ?? "?"))")
            return .allow
        }
        switch session.navigationPhase {
        case .navigating(let load), .verifying(let load, _):
            let expected = !load.started && url == load.expectedURL
            let redirecting = load.started && !load.committed
                && (url == load.expectedURL || url == session.page.url)
            if expected || redirecting {
                return .allow
            }
            let coordinated = coordinatePageNavigation(
                action.request,
                in: session,
                superseding: load
            )
            Log.webView.info("Service.navigation page-replacement domain=\(domain) session=\(session.logLabel) coordinated=\(coordinated) url=\(LogPrivacy.url(url?.absoluteString ?? "?"))")
            return .cancel
        case .settling(let settlement):
            let coordinated = coordinatePageNavigation(
                action.request,
                in: session,
                superseding: settlement.load
            )
            Log.webView.info("Service.navigation settling-replacement domain=\(domain) session=\(session.logLabel) coordinated=\(coordinated) url=\(LogPrivacy.url(url?.absoluteString ?? "?"))")
            return .cancel
        case .pending, .reserved:
            session.interruptEvaluations(with: EvalError.contextInvalidated)
            Log.webView.info("Service.navigation page-rejected-barrier domain=\(domain) session=\(session.logLabel) phase=\(session.navigationPhase.logLabel) url=\(LogPrivacy.url(url?.absoluteString ?? "?"))")
            return .cancel
        case .ready, .unavailable:
            let coordinated = coordinatePageNavigation(action.request, in: session)
            let intent = action.target == nil ? "popup" : "page"
            Log.webView.info("Service.navigation \(intent)-request domain=\(domain) session=\(session.logLabel) coordinated=\(coordinated) url=\(LogPrivacy.url(url?.absoluteString ?? "?"))")
            return .cancel
        }
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
