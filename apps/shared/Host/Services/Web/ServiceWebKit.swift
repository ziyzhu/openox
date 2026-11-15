import Foundation
import WebKit

extension BrowserSession {
    final class NavigationDecider: WebPage.NavigationDeciding {
        weak var session: BrowserSession?

        func decidePolicy(
            for action: WebPage.NavigationAction,
            preferences: inout WebPage.NavigationPreferences
        ) async -> WKNavigationActionPolicy {
            guard let session else { return .cancel }
            return await session.decidePolicy(for: action, preferences: &preferences, in: session)
        }

        func decidePolicy(for response: WebPage.NavigationResponse) async -> WKNavigationResponsePolicy {
            guard let session else { return .cancel }
            return await session.decidePolicy(for: response, in: session)
        }
    }

    final class DialogPresenter: WebPage.DialogPresenting {
        private struct SystemPresenter: WebPage.DialogPresenting {}

        weak var session: BrowserSession?

        func handleJavaScriptAlert(message: String, initiatedBy frame: WebPage.FrameInfo) async {
            guard record("alert", message, frame) else { return await SystemPresenter().handleJavaScriptAlert(message: message, initiatedBy: frame) }
        }

        func handleJavaScriptConfirm(message: String, initiatedBy frame: WebPage.FrameInfo) async -> WebPage.JavaScriptConfirmResult {
            guard record("confirm", message, frame) else { return await SystemPresenter().handleJavaScriptConfirm(message: message, initiatedBy: frame) }
            return .cancel
        }

        func handleJavaScriptPrompt(message: String, defaultText: String?, initiatedBy frame: WebPage.FrameInfo) async -> WebPage.JavaScriptPromptResult {
            guard record("prompt", message, frame) else {
                return await SystemPresenter().handleJavaScriptPrompt(message: message, defaultText: defaultText, initiatedBy: frame)
            }
            return .cancel
        }

        private func record(_ type: String, _ message: String, _ frame: WebPage.FrameInfo) -> Bool {
            guard let session else { return true }
            let presented = (try? session.manager.actionScheduler.requireNoPresentation(session)) == nil
            let origin = frame.securityOrigin
            session.recordedDialogs.append(.object([
                "type": .string(type),
                "message": .string(String(message.prefix(BrowserSession.maximumDialogMessageCharacters))),
                "origin": .string("\(origin.protocol)://\(origin.host)\(origin.port == 0 ? "" : ":\(origin.port)")"),
                "timestamp": .double(Date().timeIntervalSince1970 * 1_000),
            ]))
            session.recordedDialogs = Array(session.recordedDialogs.suffix(BrowserSession.maximumRecordedDialogs))
            Log.webView.info("BrowserSession.dialog session=\(session.logLabel) type=\(type) host=\(origin.host) disposition=\(presented ? "user" : "dismissed")")
            return !presented
        }
    }
}

extension BrowserSession {
    func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences,
        in session: BrowserSession
    ) async -> WKNavigationActionPolicy {
        session.observeFrames(action)
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

    func decidePolicy(for response: WebPage.NavigationResponse, in session: BrowserSession) async -> WKNavigationResponsePolicy {
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

extension BrowserSession: WKScriptMessageHandler {
    nonisolated func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            let frame = message.frameInfo
            let origin = frame.securityOrigin.host
            let tag = origin.isEmpty ? (frame.request.url?.host ?? "?") : origin
            guard frameServiceSources.keys.contains(where: { tag == $0 || tag.hasSuffix("." + $0) }) else { return }
            WebViewBridges.handle(message: message, tag: tag)
        }
    }
}
