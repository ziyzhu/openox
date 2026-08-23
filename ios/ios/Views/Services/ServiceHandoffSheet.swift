import SwiftUI
import WebKit

@MainActor
protocol ServiceSheetSession: AnyObject {
    var serviceDomain: String { get }
    var navigationTitle: String { get }
    var page: WebPage { get }
    func cancel()
    func goBack()
    func goForward()
    func reload()
}

extension ServiceHandoffSession: ServiceSheetSession {}

private struct ServiceSessionSheetView<Session: ServiceSheetSession>: View {
    let session: Session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ServiceBrowserWebView(page: session.page)
                .navigationTitle(session.navigationTitle)
                .navigationSubtitle(session.page.url?.host ?? session.serviceDomain)
                .navigationBarTitleDisplayMode(.inline)
                .overlay(alignment: .top) {
                    if session.page.isLoading {
                        ProgressView(value: session.page.estimatedProgress)
                            .progressViewStyle(.linear)
                    }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        Button(action: session.goBack) {
                            Image(systemName: "chevron.left")
                        }
                        .accessibilityLabel(A11yLabel.back)
                        .accessibilityIdentifier(A11yID.ServiceHandoff.back)
                        .disabled(session.page.backForwardList.backList.isEmpty)
                        Button(action: session.goForward) {
                            Image(systemName: "chevron.right")
                        }
                        .accessibilityLabel(A11yLabel.forward)
                        .accessibilityIdentifier(A11yID.ServiceHandoff.forward)
                        .disabled(session.page.backForwardList.forwardList.isEmpty)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            session.cancel()
                            dismiss()
                        }
                        .accessibilityIdentifier(A11yID.ServiceHandoff.done)
                    }
                }
        }
        .onAppear {
            Log.ui.info("ServiceSessionSheet visible domain=\(session.serviceDomain) title=\(session.navigationTitle)")
        }
        .onDisappear {
            Log.ui.info("ServiceSessionSheet hidden domain=\(session.serviceDomain) title=\(session.navigationTitle)")
            session.cancel()
        }
    }
}

private struct AppPresentationModifier: ViewModifier {
    let coordinator: AppPresentationCoordinator
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(
                get: { coordinator.presented },
                set: { if $0 == nil { coordinator.dismissPresented() } }
            )) { presented in
                switch presented.content {
                case .browser(let session):
                    ServiceBrowserView(session: session)
                case .serviceSignIn(let session):
                    ServiceSessionSheetView(session: session)
                case .serviceHandoff(let session):
                    ServiceSessionSheetView(session: session)
                }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                coordinator.setHostActive(phase == .active)
            }
            .onDisappear {
                coordinator.detachHost()
            }
    }
}

extension View {
    func appPresentations(_ coordinator: AppPresentationCoordinator) -> some View {
        modifier(AppPresentationModifier(coordinator: coordinator))
    }
}
