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

    private var currentURL: URL {
        session.page.url ?? session.initialURL
    }

    var body: some View {
        NavigationStack {
            ServiceBrowserWebView(page: session.page)
                .navigationTitle(title)
                .navigationSubtitle(currentURL.host ?? session.serviceDomain)
                .navigationBarTitleDisplayMode(.inline)
                .overlay(alignment: .top) {
                    if session.page.isLoading {
                        ProgressView(value: session.page.estimatedProgress)
                            .progressViewStyle(.linear)
                    }
                }
                .overlay {
                    if let error = session.errorMessage, !session.page.isLoading {
                        ContentUnavailableView {
                            Label("Couldn’t Load Page", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Try Again", action: session.reloadOrStop)
                        }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier(A11yID.ServiceBrowser.done)
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button(action: session.goBack) {
                            Image(systemName: "chevron.left")
                        }
                        .accessibilityIdentifier(A11yID.ServiceBrowser.back)
                        .disabled(session.page.backForwardList.backList.isEmpty)
                        Button(action: session.goForward) {
                            Image(systemName: "chevron.right")
                        }
                        .accessibilityIdentifier(A11yID.ServiceBrowser.forward)
                        .disabled(session.page.backForwardList.forwardList.isEmpty)
                        Spacer()
                        Button(action: session.reloadOrStop) {
                            Image(systemName: session.page.isLoading ? "xmark" : "arrow.clockwise")
                        }
                        .accessibilityIdentifier(A11yID.ServiceBrowser.reloadOrStop)
                        ShareLink(item: currentURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier(A11yID.ServiceBrowser.share)
                        Button(action: session.openInSystemBrowser) {
                            Image(systemName: "safari")
                        }
                        .accessibilityIdentifier(A11yID.ServiceBrowser.openInSafari)
                    }
                }
        }
        .presentationDragIndicator(.visible)
        .onAppear(perform: session.start)
        .onDisappear(perform: session.stop)
    }
}

struct ServiceBrowserWebView: View {
    let page: WebPage

    var body: some View {
        WebView(page)
            .webViewBackForwardNavigationGestures(.enabled)
            .webViewLinkPreviews(.enabled)
            .webViewMagnificationGestures(.enabled)
            .webViewTextSelection(.enabled)
            .webViewElementFullscreenBehavior(.enabled)
    }
}
