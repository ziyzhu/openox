import SwiftUI
import WebKit

struct ServicePageInspector: View {
    let service: Service
    var browserSessionID: UUID? = nil
    var pageID: UUID? = nil
    var handoff: ServiceHandoffSession? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var page: WebPage?
    @State private var servicePage: Service.ServiceWebPage?

    var body: some View {
        VStack(spacing: 0) {
            if let page {
                WebBrowserView(
                    page: page,
                    mode: .inspection,
                    fallbackHost: service.domain,
                    navigate: { url in
                        guard let servicePage else { return false }
                        return await service.navigate(url, in: servicePage) != nil
                    },
                    goBack: {
                        guard let servicePage else { return }
                        Task { await service.goBack(servicePage) }
                    },
                    goForward: {
                        guard let servicePage else { return }
                        Task { await service.goForward(servicePage) }
                    },
                    reloadOrStop: {
                        guard let servicePage else { return }
                        if page.isLoading {
                            page.stopLoading()
                        } else {
                            Task { await service.reload(servicePage) }
                        }
                    }
                )
            } else {
                CellularAutomatonLoader()
            }
            if let handoff, handoff.phase == .running {
                ServiceHandoffActions(
                    cancelAccessibilityIdentifier: "serviceHandoff.cancel",
                    doneAccessibilityIdentifier: A11yID.ServiceHandoff.done,
                    cancel: {
                        handoff.cancel()
                        dismiss()
                    },
                    done: {
                        handoff.dismissPresentation()
                        dismiss()
                    }
                )
                .padding(Theme.Spacing.md)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                SheetDismissToolbarButton(accessibilityIdentifier: A11yID.ServiceInspector.close) { dismiss() }
            }
        }
        .task {
            do {
                let inspectionPage = pageID == nil
                    ? try await service.openInspectionPage(browserSessionID: browserSessionID)
                    : nil
                guard let openedPage = pageID.flatMap({ service.servicePage(id: $0) }) ?? inspectionPage?.page else {
                    throw Service.EvalError.notActive
                }
                defer {
                    if let inspectionPage { service.closeInspectionPage(inspectionPage) }
                    self.servicePage = nil
                    page = nil
                    Log.webView.info("ServicePageInspector.close domain=\(service.domain)")
                }
                servicePage = openedPage
                page = openedPage.page
                Log.webView.info("ServicePageInspector.show domain=\(service.domain) session=\(openedPage.logLabel)")
                try await Task.sleep(for: .seconds(31_536_000))
            } catch is CancellationError {
            } catch {
                Log.webView.error("ServicePageInspector.attach failed domain=\(service.domain) error=\(error.localizedDescription)")
            }
        }
    }
}
