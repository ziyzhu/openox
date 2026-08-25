import Foundation
import Observation
import UIKit
import WebKit

@MainActor
@Observable
final class ServiceBrowserSession {
    private final class Router {
        var openPopup: @MainActor (URLRequest) -> Void = { _ in }
        var openExternal: @MainActor (URL) -> Void = { _ in }
    }

    private struct NavigationDecider: WebPage.NavigationDeciding {
        let router: Router

        mutating func decidePolicy(
            for action: WebPage.NavigationAction,
            preferences: inout WebPage.NavigationPreferences
        ) async -> WKNavigationActionPolicy {
            guard action.target?.isMainFrame != false else { return .allow }
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
    }

    let serviceDomain: String
    let serviceTitle: String
    let initialURL: URL
    let page: WebPage
    private(set) var errorMessage: String?

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
        router.openExternal = { url in UIApplication.shared.open(url) }
        #if targetEnvironment(simulator)
        page.isInspectable = true
        #endif
    }

    init(url: URL) {
        let router = Router()
        serviceDomain = url.host ?? url.absoluteString
        serviceTitle = url.host ?? url.absoluteString
        initialURL = url
        page = WebPage(navigationDecider: NavigationDecider(router: router))
        router.openPopup = { [weak self] request in self?.loadPopup(request) }
        router.openExternal = { url in UIApplication.shared.open(url) }
        #if targetEnvironment(simulator)
        page.isInspectable = true
        #endif
    }

    func start() {
        guard !started else { return }
        started = true
        errorMessage = nil
        observeNavigations()
        page.load(initialURL)
        Log.ui.info("ServiceBrowser.load domain=\(serviceDomain) url=\(LogPrivacy.url(initialURL.absoluteString))")
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

    func openInSystemBrowser() {
        UIApplication.shared.open(page.url ?? initialURL)
    }

    private func loadPopup(_ request: URLRequest) {
        errorMessage = nil
        observeNavigations()
        page.load(request)
        Log.ui.info("ServiceBrowser.popup domain=\(serviceDomain) host=\(request.url?.host?.lowercased() ?? "?") disposition=same-page")
    }
}
