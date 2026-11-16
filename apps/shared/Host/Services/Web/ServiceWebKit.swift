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
            guard record("prompt", message, frame, defaultValue: defaultText) else {
                return await SystemPresenter().handleJavaScriptPrompt(message: message, defaultText: defaultText, initiatedBy: frame)
            }
            return .cancel
        }

        func handleFileInputPrompt(parameters: WKOpenPanelParameters, initiatedBy frame: WebPage.FrameInfo) async -> WebPage.FileInputPromptResult {
            guard let session, session.events.enabled, (try? session.manager.actionScheduler.requireNoPresentation(session)) != nil else {
                return await SystemPresenter().handleFileInputPrompt(parameters: parameters, initiatedBy: frame)
            }
            session.events.append("filechooser", ["isMultiple": .bool(parameters.allowsMultipleSelection), "disposition": .string("cancelled")])
            return .cancel
        }

        private func record(_ type: String, _ message: String, _ frame: WebPage.FrameInfo, defaultValue: String? = nil) -> Bool {
            guard let session, session.events.enabled else { return false }
            let presented = (try? session.manager.actionScheduler.requireNoPresentation(session)) == nil
            guard !presented else {
                Log.webView.info("BrowserSession.dialog session=\(session.logLabel) type=\(type) disposition=user")
                return false
            }
            let origin = frame.securityOrigin
            session.events.append("dialog", [
                "type": .string(type),
                "message": .string(LogPrivacy.text(String(message.prefix(BrowserSession.maximumDialogMessageCharacters)), limit: BrowserSession.maximumDialogMessageCharacters)),
                "defaultValue": defaultValue.map { .string(String($0.prefix(BrowserSession.maximumDialogMessageCharacters))) } ?? .null,
                "origin": .string("\(origin.protocol)://\(origin.host)\(origin.port == 0 ? "" : ":\(origin.port)")"),
                "disposition": .string("dismissed"),
            ])
            return true
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
            session.events.append("popup", ["url": .string(LogPrivacy.url(url?.absoluteString ?? "")), "disposition": .string("samePage")])
            session.page.load(action.request)
            return .cancel
        }
        Log.webView.info("Service.navigation allowed domain=\(domain) session=\(session.logLabel) url=\(LogPrivacy.url(url?.absoluteString ?? "?"))")
        return .allow
    }

    func decidePolicy(for response: WebPage.NavigationResponse, in session: BrowserSession) async -> WKNavigationResponsePolicy {
        guard response.canShowMimeType else {
            session.events.append("download", [
                "url": .string(LogPrivacy.url(response.response.url?.absoluteString ?? "")),
                "suggestedFilename": .string(response.response.suggestedFilename ?? ""),
                "disposition": .string("rejected"),
            ])
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
