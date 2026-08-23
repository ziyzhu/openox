import SwiftUI
import WebKit

struct ServicePageInspector: View {
    let service: Service
    var browserSessionID: UUID? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var page: WebPage?
    @State private var servicePage: Service.ServiceWebPage?
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        Group {
            if let page {
                WebView(page)
                    .webViewBackForwardNavigationGestures(.enabled)
                    .webViewLinkPreviews(.enabled)
                    .webViewMagnificationGestures(.enabled)
                    .webViewTextSelection(.enabled)
                    .webViewElementFullscreenBehavior(.enabled)
                    .overlay(alignment: .top) {
                        if page.isLoading {
                            ProgressView(value: page.estimatedProgress)
                                .progressViewStyle(.linear)
                        }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        browserBar(page)
                    }
            } else {
                CellularAutomatonLoader()
            }
        }
        .navigationTitle(page?.title.isEmpty == false ? page?.title ?? service.title : service.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                SheetDismissToolbarButton { dismiss() }
                    .accessibilityIdentifier(A11yID.ServiceInspector.close)
            }
        }
        .onChange(of: page?.url) { _, _ in
            guard !addressFocused else { return }
            syncAddress()
        }
        .onChange(of: addressFocused) { _, _ in
            syncAddress()
        }
        .task {
            do {
                let inspectionPage = try await service.openInspectionPage(browserSessionID: browserSessionID)
                let openedPage = inspectionPage.page
                defer {
                    service.closeInspectionPage(inspectionPage)
                    self.servicePage = nil
                    page = nil
                    Log.webView.info("ServicePageInspector.close domain=\(service.domain)")
                }
                servicePage = openedPage
                page = openedPage.page
                syncAddress()
                Log.webView.info("ServicePageInspector.show domain=\(service.domain) session=\(openedPage.logLabel)")
                try await Task.sleep(for: .seconds(31_536_000))
            } catch is CancellationError {
            } catch {
                Log.webView.error("ServicePageInspector.attach failed domain=\(service.domain) error=\(error.localizedDescription)")
            }
        }
    }

    private func browserBar(_ page: WebPage) -> some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    guard let servicePage else { return }
                    Task { await service.goBack(servicePage) }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                        .frame(width: 52, height: 52)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .disabled(page.backForwardList.backList.isEmpty)

                HStack(spacing: 8) {
                    Image(systemName: page.hasOnlySecureContent ? "lock.fill" : "globe")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("Website address", text: $address)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($addressFocused)
                        .onSubmit(submitAddress)
                        .accessibilityLabel("Website address")
                        .accessibilityIdentifier(A11yID.ServiceInspector.address)
                        .font(.body)
                        .multilineTextAlignment(addressFocused ? .leading : .center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Button {
                        guard let servicePage else { return }
                        Task { await service.reload(servicePage) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(page.isLoading)
                }
                .padding(.leading, 16)
                .padding(.trailing, 4)
                .frame(height: 52)
                .glassEffect(.regular.interactive(), in: Capsule())
                .contentShape(Capsule())
                .onTapGesture(perform: beginAddressEditing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func beginAddressEditing() {
        if let url = page?.url {
            address = url.absoluteString
        }
        addressFocused = true
    }

    private func submitAddress() {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = value.contains("://") ? value : "https://\(value)"
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              let url = components.url else {
            Log.webView.warning("ServicePageInspector.address rejected domain=\(service.domain)")
            syncAddress()
            return
        }
        addressFocused = false
        Log.webView.info("ServicePageInspector.address navigate domain=\(service.domain) url=\(LogPrivacy.url(url.absoluteString))")
        Task {
            guard let servicePage else { return }
            if await service.navigate(url, in: servicePage) != nil {
                syncAddress()
            } else {
                Log.webView.error("ServicePageInspector.address failed domain=\(service.domain) url=\(LogPrivacy.url(url.absoluteString))")
                syncAddress()
            }
        }
    }

    private func syncAddress() {
        if addressFocused {
            if let url = page?.url {
                address = url.absoluteString
            }
        } else {
            address = page?.url?.host(percentEncoded: false) ?? service.domain
        }
    }
}
