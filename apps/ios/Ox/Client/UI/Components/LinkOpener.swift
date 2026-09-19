import SwiftUI
import WebKit
import UIKit

extension EnvironmentValues {
    @Entry var chatLinkHandler: ((URL) -> Void)? = nil
}

enum ChatLinkDestination: Equatable {
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
    static func open(url: URL, serviceManager: ServiceManager) {
        guard case .web = ChatLinkDestination(url) else {
            Log.ui.warning("LinkOpener.rejected url=\(LogPrivacy.url(url.absoluteString))")
            return
        }
        if let service = serviceManager.attachedService(for: url) {
            Log.ui.info("LinkOpener.open disposition=service-browser domain=\(service.domain) url=\(LogPrivacy.url(url.absoluteString))")
            let session = ServiceBrowserSession(service: service, url: url, serviceManager: serviceManager)
            if !AppPresentationCoordinator.shared.presentBrowser(session) {
                UIApplication.shared.open(url)
            }
            return
        }
        Log.ui.info("LinkOpener.open disposition=browser url=\(LogPrivacy.url(url.absoluteString))")
        let session = ServiceBrowserSession(url: url)
        if !AppPresentationCoordinator.shared.presentBrowser(session) {
            UIApplication.shared.open(url)
        }
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
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier(A11yID.ServiceBrowser.done)
                    }
                }
        }
        .presentationDragIndicator(.visible)
        .onAppear(perform: session.start)
        .onDisappear(perform: session.stop)
    }
}
