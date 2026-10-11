import AppKit
import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class ServiceBrowserSession {
    private final class Router {
        var openPopup: @MainActor (URLRequest) -> Void = { _ in }
        var openExternal: @MainActor (URL) -> Void = { _ in }
        var rejectContent: @MainActor (String) -> Void = { _ in }
    }

    private struct NavigationDecider: WebPage.NavigationDeciding {
        let router: Router

        mutating func decidePolicy(
            for action: WebPage.NavigationAction,
            preferences: inout WebPage.NavigationPreferences
        ) async -> WKNavigationActionPolicy {
            guard action.target?.isMainFrame != false else { return .allow }
            guard !action.shouldPerformDownload else {
                router.rejectContent(Self.downloadNotice)
                return .cancel
            }
            guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return .cancel }
            guard scheme == "about" || scheme == "http" || scheme == "https" else {
                router.openExternal(url)
                return .cancel
            }
            if action.target == nil {
                router.openPopup(action.request)
                return .cancel
            }
            return .allow
        }

        mutating func decidePolicy(for response: WebPage.NavigationResponse) async -> WKNavigationResponsePolicy {
            let attachment = (response.response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Disposition")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased().hasPrefix("attachment") == true
            guard response.canShowMimeType, !attachment else {
                router.rejectContent(attachment
                    ? Self.downloadNotice
                    : String(localized: "Ox’s browser can’t display this content. The current page has been kept."))
                return .cancel
            }
            return .allow
        }

        private static var downloadNotice: String {
            String(localized: "Downloads aren’t supported in Ox’s browser yet. The current page has been kept.")
        }
    }

    let serviceDomain: String
    let serviceTitle: String
    let initialURL: URL
    let page: WebPage
    private(set) var errorMessage: String?
    private(set) var navigationNotice: String?

    private var navigationTask: Task<Void, Never>?
    private var started = false

    init(service: Service, url: URL, serviceManager: ServiceManager) {
        let router = Router()
        serviceDomain = service.domain
        serviceTitle = service.title
        initialURL = url
        page = WebPage(
            configuration: serviceManager.makeBrowserPageConfiguration(for: service.domain),
            navigationDecider: NavigationDecider(router: router)
        )
        router.openPopup = { [weak self] request in self?.loadPopup(request) }
        router.openExternal = { [weak self] url in self?.openExternal(url) }
        router.rejectContent = { [weak self] message in self?.rejectContent(message) }
        #if targetEnvironment(simulator)
        page.isInspectable = true
        #endif
    }

    init(url: URL, serviceManager: ServiceManager? = nil) {
        let router = Router()
        serviceDomain = url.host ?? url.absoluteString
        serviceTitle = url.host ?? url.absoluteString
        initialURL = url
        if let serviceManager {
            page = WebPage(
                configuration: serviceManager.makeBrowserPageConfiguration(for: serviceDomain),
                navigationDecider: NavigationDecider(router: router)
            )
        } else {
            page = WebPage(navigationDecider: NavigationDecider(router: router))
        }
        router.openPopup = { [weak self] request in self?.loadPopup(request) }
        router.openExternal = { [weak self] url in self?.openExternal(url) }
        router.rejectContent = { [weak self] message in self?.rejectContent(message) }
        #if targetEnvironment(simulator)
        page.isInspectable = true
        #endif
    }

    func dismissNavigationNotice() {
        navigationNotice = nil
    }

    private func rejectContent(_ message: String) {
        navigationNotice = message
        Log.ui.warning("ServiceBrowser.content rejected domain=\(serviceDomain) reason=\(LogPrivacy.text(message))")
    }

    private func openExternal(_ url: URL) {
        let opened = NSWorkspace.shared.open(url)
        if !opened { navigationNotice = String(localized: "No available app could open this link. The current page has been kept.") }
        Log.ui.info("ServiceBrowser.external platform=macos scheme=\(url.scheme ?? "none") opened=\(opened)")
    }

    func start() {
        guard !started else { return }
        started = true
        errorMessage = nil
        observeNavigations()
        page.load(initialURL)
        Log.ui.info("ServiceBrowser.load domain=\(serviceDomain) url=\(LogPrivacy.url(initialURL.absoluteString))")
    }

    func navigate(to url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        errorMessage = nil
        observeNavigations()
        page.load(url)
        return true
    }

    private func observeNavigations() {
        guard navigationTask == nil else { return }
        navigationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { navigationTask = nil }
            do {
                for try await event in page.navigations {
                    guard !Task.isCancelled else { return }
                    if event == .startedProvisionalNavigation {
                        errorMessage = nil
                    }
                    Log.ui.info("ServiceBrowser.navigation domain=\(serviceDomain) event=\(String(describing: event)) host=\(page.url?.host?.lowercased() ?? "?")")
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                Log.ui.error("ServiceBrowser.navigation failed domain=\(serviceDomain) error=\(LogPrivacy.text(error.localizedDescription))")
            }
        }
    }

    func stop() {
        navigationTask?.cancel()
        navigationTask = nil
        page.stopLoading()
    }

    func goBack() {
        guard let item = page.backForwardList.backList.last else { return }
        observeNavigations()
        page.load(item)
    }

    func goForward() {
        guard let item = page.backForwardList.forwardList.first else { return }
        observeNavigations()
        page.load(item)
    }

    func reloadOrStop() {
        errorMessage = nil
        if page.isLoading {
            page.stopLoading()
        } else {
            observeNavigations()
            page.reload()
        }
    }

    private func loadPopup(_ request: URLRequest) {
        errorMessage = nil
        observeNavigations()
        page.load(request)
        Log.ui.info("ServiceBrowser.popup domain=\(serviceDomain) host=\(request.url?.host?.lowercased() ?? "?") disposition=same-page")
    }
}
