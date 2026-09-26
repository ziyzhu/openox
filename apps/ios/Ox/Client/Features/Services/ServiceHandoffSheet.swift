import SwiftUI
import WebKit
import UIKit

@MainActor
protocol ServiceSheetSession: AnyObject {
    var id: UUID { get }
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

struct BotControlSheetView: View {
    let session: ServiceHandoffSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WebBrowserView(
                page: session.page,
                mode: .handoff,
                fallbackHost: session.serviceDomain,
                navigate: { session.navigate(to: $0) },
                goBack: { session.goBack() },
                goForward: { session.goForward() },
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        session.cancel()
                        dismiss()
                    }
                    .accessibilityIdentifier(A11yID.Chat.Attach.botControlCancel(session.serviceDomain))
                }
            }
        }
        .interactiveDismissDisabled()
        .onAppear {
            Log.ui.info("BotControlSheet visible domain=\(session.serviceDomain) title=\(session.navigationTitle)")
        }
        .onDisappear {
            Log.ui.info("BotControlSheet hidden domain=\(session.serviceDomain) title=\(session.navigationTitle)")
        }
    }
}

private struct ServiceSessionSheetView<Session: ServiceSheetSession>: View {
    let session: Session
    let mode: WebBrowserView.Mode
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            WebBrowserView(
                page: session.page,
                mode: mode,
                fallbackHost: session.serviceDomain,
                navigate: { session.navigate(to: $0) },
                goBack: { session.goBack() },
                goForward: { session.goForward() },
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
                        Button("Cancel", role: .cancel) {
                            session.cancel()
                            dismiss()
                        }
                        .accessibilityIdentifier(A11yID.ServiceHandoff.done)
                    }
                }
        }
        .onAppear {
            Log.ui.info("ServiceSessionSheet visible domain=\(session.serviceDomain) attempt=\(session.id.uuidString.prefix(8)) title=\(session.navigationTitle) uptime=\(ProcessInfo.processInfo.systemUptime)")
        }
        .onDisappear {
            Log.ui.info("ServiceSessionSheet hidden domain=\(session.serviceDomain) attempt=\(session.id.uuidString.prefix(8)) title=\(session.navigationTitle) uptime=\(ProcessInfo.processInfo.systemUptime)")
            session.cancel()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            Log.ui.info("ServiceSessionSheet scene domain=\(session.serviceDomain) attempt=\(session.id.uuidString.prefix(8)) phase=\(String(describing: phase)) uptime=\(ProcessInfo.processInfo.systemUptime)")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            logKeyboard(notification, event: "willChangeFrame")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { notification in
            logKeyboard(notification, event: "didHide")
        }
    }

    private func logKeyboard(_ notification: Notification, event: String) {
        let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? -1
        let local = notification.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool ?? false
        Log.ui.info("ServiceSessionSheet keyboard domain=\(session.serviceDomain) attempt=\(session.id.uuidString.prefix(8)) event=\(event) local=\(local) endY=\(frame?.minY ?? -1) height=\(frame?.height ?? -1) duration=\(duration) loading=\(session.page.isLoading) uptime=\(ProcessInfo.processInfo.systemUptime)")
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
