import SwiftUI
import WebKit
import UIKit

struct WebBrowserView: View {
    enum ChromeLayout {
        case overlay
        case reserved
    }

    enum Mode {
        case browse
        case inspection
        case signIn
        case handoff

        var allowsAddressEditing: Bool { self != .handoff }
        var allowsSharing: Bool { self == .browse || self == .inspection }

        var accessibilityPrefix: String {
            switch self {
            case .browse: "serviceBrowser"
            case .inspection: "serviceInspector"
            case .signIn, .handoff: "serviceHandoff"
            }
        }
    }

    private enum AddressError {
        case invalid
        case blocked

        var message: LocalizedStringKey {
            switch self {
            case .invalid: "Enter a valid website address."
            case .blocked: "Couldn’t open this address in this session."
            }
        }
    }

    private enum ScrollChrome {
        case expanded(anchor: CGFloat)
        case compact(anchor: CGFloat)
        case revealed(anchor: CGFloat)

        var isCompact: Bool {
            if case .compact = self { return true }
            return false
        }

        mutating func update(offset: CGFloat) {
            if offset < 16 {
                self = .expanded(anchor: offset)
                return
            }
            switch self {
            case .expanded(let anchor):
                let anchor = min(anchor, offset)
                self = offset - anchor >= 48 ? .compact(anchor: offset) : .expanded(anchor: anchor)
            case .compact(let anchor):
                let anchor = max(anchor, offset)
                self = anchor - offset >= 24 ? .expanded(anchor: offset) : .compact(anchor: anchor)
            case .revealed:
                self = .revealed(anchor: offset)
            }
        }

        mutating func beginScrolling() {
            if case .revealed(let anchor) = self { self = .expanded(anchor: anchor) }
        }
    }

    let page: WebPage
    let mode: Mode
    var chromeLayout: ChromeLayout = .overlay
    let fallbackHost: String
    var initialURL: URL? = nil
    var errorMessage: String? = nil
    let navigate: @MainActor (URL) async -> Bool
    let goBack: @MainActor () -> Void
    let goForward: @MainActor () -> Void
    let reloadOrStop: @MainActor () -> Void
    @State private var address = ""
    @State private var addressError: AddressError?
    @State private var scrollChrome = ScrollChrome.expanded(anchor: 0)
    @FocusState private var addressFocused: Bool
    @Namespace private var barNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var currentURL: URL? { page.url ?? initialURL }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if chromeLayout == .reserved {
                    VStack(spacing: 0) {
                        websiteContent
                            .overlay { errorOverlay }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        browserBar
                            .background(Theme.Colors.surface)
                    }
                } else {
                    websiteContent
                        .ignoresSafeArea(.container, edges: .bottom)
                        .overlay { errorOverlay }
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            browserBar
                                .offset(y: scrollChrome.isCompact && !addressFocused ? max(0, geometry.safeAreaInsets.bottom - 16) : 0)
                                .animation(reduceMotion ? nil : Theme.Animation.handoff, value: addressFocused)
                                .animation(reduceMotion ? nil : Theme.Animation.handoff, value: scrollChrome.isCompact)
                        }
                }
            }
            .onChange(of: currentURL, initial: true) { _, _ in
                scrollChrome = .expanded(anchor: 0)
                guard !addressFocused else { return }
                syncAddress()
            }
            .onChange(of: addressFocused) { _, focused in
                syncAddress()
                if focused {
                    scrollChrome = .expanded(anchor: 0)
                    Task { @MainActor in
                        await Task.yield()
                        guard addressFocused else { return }
                        UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                    }
                }
            }
            .alert("Couldn’t Load Page", isPresented: Binding(
                get: { addressError != nil },
                set: { if !$0 { addressError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                if let addressError { Text(addressError.message) }
            }
        }
    }

    private var websiteContent: some View {
        WebContentView(page: page)
            .simultaneousGesture(DragGesture().onChanged { _ in scrollChrome.beginScrolling() })
            .webViewOnScrollGeometryChange(for: CGFloat.self) { geometry in
                let maximum = max(0, geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom - geometry.containerSize.height)
                let offset = min(maximum, max(0, geometry.contentOffset.y + geometry.contentInsets.top))
                return (offset / 8).rounded(.down) * 8
            } action: { _, offset in
                guard !addressFocused, !page.isLoading else { return }
                scrollChrome.update(offset: offset)
            }
    }

    @ViewBuilder private var errorOverlay: some View {
        if let errorMessage, !page.isLoading {
            ContentUnavailableView {
                Label("Couldn’t Load Page", systemImage: "wifi.exclamationmark")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again", action: reloadOrStop)
            }
        }
    }

    private var browserBar: some View {
        GlassEffectContainer(spacing: 8) {
            if scrollChrome.isCompact, !addressFocused {
                Button {
                    if case .compact(let anchor) = scrollChrome {
                        scrollChrome = .revealed(anchor: anchor)
                    }
                } label: {
                    Text(currentURL?.host(percentEncoded: false) ?? fallbackHost)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                        .frame(height: 28)
                        .glassEffect(.regular.interactive(), in: Capsule())
                        .glassEffectID("address", in: barNamespace)
                        .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .bottom)
                .contentShape(Rectangle())
                .accessibilityLabel("Website address")
                .accessibilityValue(currentURL?.host(percentEncoded: false) ?? fallbackHost)
                .accessibilityIdentifier(identifier("collapsedAddress"))
            } else {
                expandedBar
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.top, 8)
        .padding(.bottom, Theme.Spacing.sm)
    }

    private var expandedBar: some View {
        HStack(spacing: 8) {
            if !addressFocused {
                HStack(spacing: 0) {
                    Button(action: goBack) {
                        controlSymbol("chevron.left", width: page.backForwardList.forwardList.isEmpty ? 48 : 40, font: .system(size: 21))
                    }
                    .accessibilityLabel(A11yLabel.back)
                    .accessibilityIdentifier(identifier("back"))
                    .disabled(page.backForwardList.backList.isEmpty)
                    if !page.backForwardList.forwardList.isEmpty {
                        Button(action: goForward) {
                            controlSymbol("chevron.right", width: 40, font: .system(size: 21))
                        }
                        .accessibilityLabel(A11yLabel.forward)
                        .accessibilityIdentifier(identifier("forward"))
                    }
                }
                .glassEffect(.regular.interactive(), in: Capsule())
                .glassEffectID("navigation", in: barNamespace)
                .glassEffectTransition(reduceMotion ? .identity : .materialize)
            }
            addressBar
            if addressFocused {
                Button { addressFocused = false } label: {
                    controlSymbol("xmark")
                }
                .accessibilityLabel("Cancel")
                .accessibilityIdentifier(identifier("cancelEditing"))
                .glassEffect(.regular.interactive(), in: Circle())
                .glassEffectID("cancelEditing", in: barNamespace)
                .glassEffectTransition(reduceMotion ? .identity : .materialize)
                .transition(.identity)
            } else if mode.allowsSharing, let currentURL {
                Menu {
                    ShareLink(item: currentURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier(identifier("share"))
                    Button {
                        UIApplication.shared.open(currentURL)
                    } label: {
                        Label("Open in Safari", systemImage: "safari")
                    }
                    .accessibilityIdentifier(identifier("openInSafari"))
                } label: {
                    controlSymbol("ellipsis")
                }
                .accessibilityLabel(A11yLabel.more)
                .accessibilityIdentifier(identifier("more"))
                .glassEffect(.regular.interactive(), in: Circle())
                .glassEffectID("more", in: barNamespace)
                .glassEffectTransition(reduceMotion ? .identity : .materialize)
            }
        }
        .buttonStyle(.plain)
    }

    private func controlSymbol(_ name: String, width: CGFloat = 48, font: Font = .title3) -> some View {
        Image(systemName: name)
            .font(font)
            .frame(width: width, height: 48)
            .contentShape(Rectangle())
    }

    private var addressBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                Image(systemName: currentURL?.scheme == "https" && page.hasOnlySecureContent ? "lock.fill" : "globe")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 48)
                if mode.allowsAddressEditing {
                    ZStack {
                        TextField("Website address", text: $address)
                            .textFieldStyle(.plain)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .focused($addressFocused)
                            .onSubmit(submitAddress)
                            .accessibilityLabel("Website address")
                            .accessibilityIdentifier(identifier("address"))
                            .opacity(addressFocused ? 1 : 0)
                            .accessibilityHidden(!addressFocused)
                        if !addressFocused {
                            Button { addressFocused = true } label: {
                                Text(address)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .accessibilityLabel("Website address")
                            .accessibilityValue(address)
                            .accessibilityIdentifier(identifier("address"))
                            .transition(.identity)
                        }
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text(currentURL?.host(percentEncoded: false) ?? fallbackHost)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier(identifier("address"))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .onTapGesture {
                if mode.allowsAddressEditing { addressFocused = true }
            }
            if !addressFocused {
                Button(action: reloadOrStop) {
                    controlSymbol(page.isLoading ? "xmark" : "arrow.clockwise", width: 40)
                }
                .accessibilityLabel(page.isLoading ? A11yLabel.stop : String(localized: "Reload"))
                .accessibilityIdentifier(identifier("reloadOrStop"))
            }
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 48)
        .overlay(alignment: .bottom) {
            if page.isLoading {
                ProgressView(value: page.estimatedProgress)
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 20)
            }
        }
        .glassEffect(.regular.interactive(), in: Capsule())
        .glassEffectID("address", in: barNamespace)
        .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
    }

    private func submitAddress() {
        guard let url = Self.url(from: address) else {
            Log.webView.warning("WebBrowser.address rejected mode=\(mode.accessibilityPrefix) reason=invalid")
            addressError = .invalid
            return
        }
        addressFocused = false
        Log.webView.info("WebBrowser.address navigate mode=\(mode.accessibilityPrefix) host=\(url.host ?? "?")")
        Task {
            guard await navigate(url) else {
                addressError = .blocked
                return
            }
        }
    }

    private func syncAddress() {
        address = addressFocused
            ? currentURL?.absoluteString ?? ""
            : currentURL?.host(percentEncoded: false) ?? fallbackHost
    }

    private func identifier(_ control: String) -> String {
        "\(mode.accessibilityPrefix).\(control)"
    }

    static func url(from address: String) -> URL? {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }) else { return nil }
        let candidate = value.contains("://") ? value : "https://\(value)"
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil else { return nil }
        return components.url
    }
}

struct WebContentView: View {
    enum Mode {
        case browser
        case canvas
    }

    let page: WebPage
    var mode: Mode = .browser

    var body: some View {
        WebView(page)
            .webViewBackForwardNavigationGestures(mode == .browser ? .enabled : .disabled)
            .webViewLinkPreviews(.enabled)
            .webViewMagnificationGestures(.enabled)
            .webViewTextSelection(.enabled)
            .webViewElementFullscreenBehavior(.enabled)
    }
}
