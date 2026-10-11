import SwiftUI
import WebKit
import UIKit

extension EnvironmentValues {
    @Entry var conversationLinkHandler: ((URL) -> Void)? = nil
}

enum ConversationLinkDestination: Equatable {
    case web(URL)
    case artifact(String)
    case unsupported(URL)

    init(_ url: URL) {
        switch url.scheme?.lowercased() {
        case "http", "https":
            self = .web(url)
        case "sandbox":
            let filename = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            self = filename.isEmpty ? .unsupported(url) : .artifact(filename)
        default:
            self = .unsupported(url)
        }
    }
}

@MainActor
enum LinkOpener {
    @discardableResult
    static func open(url: URL, serviceManager: ServiceManager) -> Bool {
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

    private var title: String {
        session.page.title.isEmpty ? session.serviceTitle : session.page.title
    }

    var body: some View {
        NavigationStack {
            browser
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { doneButton }
                }
        }
        .onAppear(perform: session.start)
        .onDisappear(perform: session.stop)
        .alert("Couldn’t Open Link", isPresented: Binding(
            get: { session.navigationNotice != nil },
            set: { if !$0 { session.dismissNavigationNotice() } }
        )) {
            Button("OK") { session.dismissNavigationNotice() }
                .accessibilityIdentifier("serviceBrowser.dismissNavigationNotice")
        } message: {
            Text(session.navigationNotice ?? "")
        }
    }

    private var browser: some View {
        WebBrowserView(
            page: session.page,
            mode: .browse,
            fallbackHost: session.serviceDomain,
            initialURL: session.initialURL,
            errorMessage: session.errorMessage,
            navigate: { session.navigate(to: $0) },
            goBack: session.goBack,
            goForward: session.goForward,
            reloadOrStop: session.reloadOrStop
        )
    }

    private var doneButton: some View {
        Button("Done") { dismiss() }
            .accessibilityIdentifier(A11yID.ServiceBrowser.done)
    }
}
