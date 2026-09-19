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
    func navigate(to url: URL) -> Bool
}

extension ServiceHandoffSession: ServiceSheetSession {}

private struct ServiceSessionSheetView<Session: ServiceSheetSession>: View {
    let session: Session
    let mode: WebBrowserView.Mode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WebBrowserView(
                page: session.page,
                mode: mode,
                fallbackHost: session.serviceDomain,
                navigate: { session.navigate(to: $0) },
                goBack: session.goBack,
                goForward: session.goForward,
                reloadOrStop: {
                    if session.page.isLoading {
                        session.page.stopLoading()
                    } else {
                        session.reload()
                    }
                }
            )
                .navigationTitle(session.navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
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
                    ServiceSessionSheetView(session: session, mode: .signIn)
                case .serviceHandoff(let session):
                    ServiceSessionSheetView(session: session, mode: .handoff)
                case .providerAuthentication(let session):
                    ProviderAuthenticationSheet(session: session)
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
