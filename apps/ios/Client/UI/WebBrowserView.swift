import SwiftUI
import WebKit
import UIKit

struct WebBrowserView: View {
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
    let fallbackHost: String
    var initialURL: URL? = nil
    var errorMessage: String? = nil
    var startPage: AnyView? = nil
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

    private var chromeAnimation: Animation? {
        reduceMotion ? nil : .spring(duration: 0.28, bounce: 0)
    }

    private var chromeFade: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.16)
    }

    var body: some View {
        GeometryReader { geometry in
            websiteContent
                .overlay { errorOverlay }
                .overlay { if currentURL == nil, let startPage { startPage } }
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    browserBar
                        .padding(.bottom, isCompact ? -min(20, geometry.safeAreaInsets.bottom) : 0)
                }
        }
            .animation(chromeAnimation, value: addressFocused)
            .animation(chromeAnimation, value: scrollChrome.isCompact)
            .task {
                guard currentURL == nil, startPage != nil, mode.allowsAddressEditing else { return }
                addressFocused = true
            }
            .onChange(of: currentURL, initial: true) { previous, current in
                if previous == nil, current != nil { addressFocused = false }
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
            .toolbarBackground(.hidden, for: .navigationBar)
    }

    private var websiteContent: some View {
        WebContentView(page: page)
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
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

    private var isCompact: Bool { scrollChrome.isCompact && !addressFocused }

    private var browserBar: some View {
        GlassEffectContainer(spacing: 8) {
            expandedBar
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, Theme.Spacing.sm)
    }

    private var expandedBar: some View {
        HStack(spacing: isCompact ? 0 : 8) {
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
                .opacity(isCompact ? 0 : 1)
                .glassEffect(isCompact ? .identity : .regular.interactive(), in: Capsule())
                .glassEffectID("navigation", in: barNamespace)
                .glassEffectTransition(.identity)
                .animation(chromeFade, value: isCompact)
                .scaleEffect(isCompact ? 0.65 : 1)
                .frame(width: isCompact ? 0 : page.backForwardList.forwardList.isEmpty ? 48 : 80)
                .allowsHitTesting(!isCompact)
                .accessibilityHidden(isCompact)
                .transition(reduceMotion ? .identity : .opacity)
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
                .opacity(isCompact ? 0 : 1)
                .glassEffect(isCompact ? .identity : .regular.interactive(), in: Circle())
                .glassEffectID("more", in: barNamespace)
                .glassEffectTransition(.identity)
                .animation(chromeFade, value: isCompact)
                .scaleEffect(isCompact ? 0.65 : 1)
                .frame(width: isCompact ? 0 : 48)
                .allowsHitTesting(!isCompact)
                .accessibilityHidden(isCompact)
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
    }

    private func controlSymbol(_ name: String, width: CGFloat = 48, font: Font = .title3) -> some View {
        Image(systemName: name)
            .font(font)
            .frame(width: width, height: 48)
            .contentShape(Rectangle())
    }

    private var domainLabel: some View {
        let host = currentURL?.host(percentEncoded: false) ?? fallbackHost
        return Text(host.isEmpty ? String(localized: "Website address") : host)
            .foregroundStyle(host.isEmpty ? .secondary : .primary)
            .lineLimit(1)
    }

    private var addressBar: some View {
        HStack(spacing: 0) {
            Button {
                if case .compact(let anchor) = scrollChrome {
                    scrollChrome = .revealed(anchor: anchor)
                    Log.webView.info("WebBrowser.chrome reveal mode=\(mode.accessibilityPrefix)")
                } else if mode.allowsAddressEditing {
                    addressFocused = true
                }
            } label: {
                domainLabel
                    .font(.system(size: isCompact ? 13 : 17, weight: isCompact ? .medium : .regular))
                    .padding(.horizontal, isCompact ? 24 : 0)
                    .frame(maxWidth: isCompact ? nil : .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!isCompact && !mode.allowsAddressEditing)
            .accessibilityLabel("Website address")
            .accessibilityValue(address)
            .accessibilityIdentifier(identifier(isCompact ? "collapsedAddress" : "address"))
            .opacity(addressFocused ? 0 : 1)
            .animation(nil, value: addressFocused)
            .accessibilityHidden(addressFocused)
            .overlay {
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
                    .frame(minHeight: 44)
                    .opacity(addressFocused ? 1 : 0)
                    .animation(nil, value: addressFocused)
                    .accessibilityHidden(!addressFocused)
                    .allowsHitTesting(addressFocused)
            }
            if addressFocused, !address.isEmpty {
                Button {
                    address = ""
                } label: {
                    controlSymbol("xmark.circle.fill", width: 40, font: .body)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear address")
                .accessibilityIdentifier(identifier("clearAddress"))
            } else if !addressFocused {
                Button(action: reloadOrStop) {
                    controlSymbol(page.isLoading ? "xmark" : "arrow.clockwise", width: 40)
                }
                .accessibilityLabel(page.isLoading ? A11yLabel.stop : String(localized: "Reload"))
                .accessibilityIdentifier(identifier("reloadOrStop"))
                .disabled(currentURL == nil)
                .opacity(isCompact ? 0 : 1)
                .animation(chromeFade, value: isCompact)
                .frame(width: isCompact ? 0 : 40)
                .allowsHitTesting(!isCompact)
                .accessibilityHidden(isCompact)
            }
        }
        .padding(.leading, isCompact ? 0 : addressFocused ? 16 : 4)
        .padding(.trailing, isCompact ? 0 : 4)
        .frame(minHeight: isCompact ? 44 : 48)
        .overlay(alignment: .bottom) {
            if page.isLoading {
                ProgressView(value: page.estimatedProgress)
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 20)
            }
        }
        .glassEffect(.regular.interactive(), in: Capsule().inset(by: isCompact ? 8 : 0))
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
            .excludesCompactPageSwitch()
            .webViewBackForwardNavigationGestures(mode == .browser ? .enabled : .disabled)
            .webViewLinkPreviews(.enabled)
            .webViewMagnificationGestures(.enabled)
            .webViewTextSelection(.enabled)
            .webViewElementFullscreenBehavior(.enabled)
    }
}
