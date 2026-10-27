import SwiftUI
import WebKit
import UIKit

struct ConversationFileResolver {
    let revision: Int
    let resolve: (String) async -> FileItem?
    let read: (String) async throws -> JSONValue
}

extension EnvironmentValues {
    @Entry var conversationLinkHandler: ((URL) -> Void)? = nil
    @Entry var conversationFileResolver: ConversationFileResolver? = nil
}

enum ConversationLinkDestination: Equatable {
    case web(URL)
    case external(URL)
    case conversationFile(String)
    case file(String)
    case unsupported(URL)

    init(_ url: URL) {
        switch url.scheme?.lowercased() {
        case "http", "https":
            self = .web(url)
        case "tel", "mailto", "sms", "facetime", "facetime-audio":
            self = .external(url)
        case nil:
            let path = url.relativeString.removingPercentEncoding ?? url.relativeString
            self = path.isEmpty ? .unsupported(url) : .file(path)
        case "sandbox":
            let filename = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            self = filename.isEmpty ? .unsupported(url) : .conversationFile(filename)
        default:
            self = .unsupported(url)
        }
    }
}

@MainActor
enum LinkOpener {
    @discardableResult
    static func open(url: URL, serviceManager: ServiceManager, onFailure: (() -> Void)? = nil) -> Bool {
        if case .external = ConversationLinkDestination(url) {
            UIApplication.shared.open(url, options: [:]) { opened in
                Log.ui.info("LinkOpener.open disposition=external scheme=\(url.scheme ?? "?") opened=\(opened)")
                if !opened { onFailure?() }
            }
            return true
        }
        guard case .web = ConversationLinkDestination(url) else {
            Log.ui.warning("LinkOpener.rejected url=\(LogPrivacy.url(url.absoluteString))")
            return false
        }
        let coordinator = AppPresentationCoordinator.shared
        if case .browser(let session) = coordinator.presented?.content {
            return session.navigate(to: url)
        }
        guard coordinator.canOpenBrowser else { return false }
        let session: ServiceBrowserSession
        if let service = serviceManager.attachedService(for: url) {
            session = ServiceBrowserSession(service: service, url: url, serviceManager: serviceManager)
        } else {
            session = ServiceBrowserSession(url: url, serviceManager: serviceManager)
        }
        Log.ui.info("LinkOpener.open disposition=browser url=\(LogPrivacy.url(url.absoluteString))")
        return coordinator.presentBrowser(session)
    }

    @discardableResult
    static func openStartPage(serviceManager: ServiceManager) -> Bool {
        let coordinator = AppPresentationCoordinator.shared
        guard coordinator.canOpenBrowser else { return false }
        Log.ui.info("LinkOpener.open disposition=start-page")
        return coordinator.presentBrowser(ServiceBrowserSession(serviceManager: serviceManager))
    }
}

struct ServiceBrowserView: View {
    let session: ServiceBrowserSession
    @State private var toast: Toast?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            browser
                .toast($toast, accessibilityIdentifier: "serviceBrowser.navigationNotice")
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { doneButton }
                }
        }
        .onAppear(perform: session.start)
        .onDisappear(perform: session.stop)
        .onChange(of: session.navigationNotice, initial: true) { _, message in
            toast = message.map { Toast(message: $0, role: .error) }
        }
        .onChange(of: toast?.id) { _, _ in
            if toast == nil { session.dismissNavigationNotice() }
        }
    }

    private var browser: some View {
        WebBrowserView(
            page: session.page,
            mode: .browse,
            fallbackHost: session.serviceDomain,
            initialURL: session.initialURL,
            errorMessage: session.errorMessage,
            startPage: AnyView(BrowserStartPage { url in
                Log.ui.info("ServiceBrowser.startPage open host=\(url.host ?? "?")")
                _ = session.navigate(to: url)
            }),
            navigate: { session.navigate(to: $0) },
            goBack: session.goBack,
            goForward: session.goForward,
            reloadOrStop: session.reloadOrStop
        )
    }

    private var doneButton: some View {
        SheetDismissToolbarButton(accessibilityIdentifier: A11yID.ServiceBrowser.done) { dismiss() }
    }
}
