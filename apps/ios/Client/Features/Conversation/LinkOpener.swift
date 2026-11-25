import SwiftUI
import WebKit
import UIKit

struct ConversationFileResolver: Equatable {
    let conversationID: UUID
    let revision: Int
    let resolve: (String) async -> FileItem?
    let read: (String) async throws -> JSONValue

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.conversationID == rhs.conversationID && lhs.revision == rhs.revision
    }
}

struct OpenConversationAction: Equatable {
    let sourceConversationID: UUID
    let perform: (UUID) -> Void

    func callAsFunction(_ id: UUID) {
        perform(id)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sourceConversationID == rhs.sourceConversationID
    }
}

private struct OpenConversationKey: EnvironmentKey {
    static let defaultValue: OpenConversationAction? = nil
}

private struct ConversationLinkHandlerKey: EnvironmentKey {
    static let defaultValue: LinkRouter? = nil
}

extension EnvironmentValues {
    var openConversation: OpenConversationAction? {
        get { self[OpenConversationKey.self] }
        set { self[OpenConversationKey.self] = newValue }
    }
    var conversationLinkHandler: LinkRouter? {
        get { self[ConversationLinkHandlerKey.self] }
        set { self[ConversationLinkHandlerKey.self] = newValue }
    }
    @Entry var conversationFileResolver: ConversationFileResolver? = nil
    @Entry var conversationViewport: ConversationViewportController? = nil
}

@MainActor
final class LinkRouter {
    private var route: (URL) -> Void = { _ in }

    func routing(_ route: @escaping (URL) -> Void) -> LinkRouter {
        self.route = route
        return self
    }

    func callAsFunction(_ url: URL) {
        route(url)
    }
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

}

struct ServiceBrowserView: View {
    let session: ServiceBrowserSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ServiceBrowserContent(session: session, close: (A11yID.ServiceBrowser.close, { dismiss() }))
        }
        .onDisappear(perform: session.stop)
    }
}

struct ServiceBrowserContent: View {
    let session: ServiceBrowserSession
    var showsBrowserBar = true
    var close: (accessibilityIdentifier: String, action: @MainActor () -> Void)? = nil
    @State private var toast: Toast?

    var body: some View {
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
            showsBrowserBar: showsBrowserBar,
            close: close,
            navigate: { session.navigate(to: $0) },
            goBack: session.goBack,
            goForward: session.goForward,
            reloadOrStop: session.reloadOrStop
        )
        .toast($toast, accessibilityIdentifier: "serviceBrowser.navigationNotice")
        .onAppear(perform: session.start)
        .onChange(of: session.navigationNotice, initial: true) { _, message in
            toast = message.map { Toast(message: $0, role: .error) }
        }
        .onChange(of: toast?.id) { _, _ in
            if toast == nil { session.dismissNavigationNotice() }
        }
    }
}
