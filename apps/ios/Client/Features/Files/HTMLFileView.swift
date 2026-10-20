import MapKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct HTMLFileScreen: View {
    let file: FileItem
    let scope: ProfileScope?
    @State private var changes = 0

    init(file: FileItem, scope: ProfileScope? = StorageRoot.currentScope) {
        self.file = file
        self.scope = scope
    }

    var body: some View {
        GeometryReader { geometry in
            HTMLFileView(
                file: file,
                scope: scope,
                modifiedAt: file.modifiedAt,
                safeAreaInsets: geometry.safeAreaInsets
            )
            .id(changes)
        }
        .onPresentedFileChange(file.fileURL) {
            changes += 1
            Log.ui.info("HTMLFileScreen.fileChanged filename=\(file.fileName) changes=\(changes)")
        }
        .background(Theme.Colors.conversationSurface)
        .navigationTitle(file.userFacingName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                FileShareButton(file: file, scope: scope) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel(A11yLabel.shareFile)
                .accessibilityIdentifier(A11yID.Files.share(file.id))
            }
        }
    }
}

struct HTMLFileView: View {
    let file: FileItem
    let modifiedAt: Date?
    let safeAreaInsets: EdgeInsets
    private let source: FilePreviewSource

    init(file: FileItem, scope: ProfileScope?, modifiedAt: Date?, safeAreaInsets: EdgeInsets) {
        self.file = file
        self.modifiedAt = modifiedAt
        self.safeAreaInsets = safeAreaInsets
        source = FilePreviewSource(file: file, scope: scope)
    }

    private enum Phase {
        case loadingFile
        case loadingHTML(HTMLFileDocument)
        case ready(HTMLFileDocument)
        case failed(String)

        var isLoading: Bool {
            switch self {
            case .loadingFile, .loadingHTML: true
            case .ready, .failed: false
            }
        }

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    @Environment(ServiceManager.self) private var serviceManager
    @State private var phase: Phase = .loadingFile

    var body: some View {
        ZStack {
            switch phase {
            case .loadingFile:
                Color.clear
            case .loadingHTML(let document), .ready(let document):
                HTMLFileWebView(
                    document: document,
                    title: file.userFacingName,
                    serviceManager: serviceManager,
                    safeAreaInsets: safeAreaInsets,
                    isReady: phase.isReady,
                    onNavigation: { handleNavigation($0, document: document) }
                )
                .id(document)
            case .failed(let message):
                ContentUnavailableView(
                    "File unavailable",
                    systemImage: file.exists ? "exclamationmark.triangle" : "questionmark.folder",
                    description: Text(message)
                )
            }
            if phase.isLoading {
                HTMLFileLoadingView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.conversationSurface)
        .task(id: modifiedAt) { await load() }
    }

    private func load() async {
        phase = .loadingFile
        do {
            let document = try await HTMLFileDocument.read(source)
            guard !Task.isCancelled else { return }
            phase = .loadingHTML(document)
            Log.ui.info("HTMLFileView.load filename=\(file.fileName) bytes=\(document.byteCount)")
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
            Log.ui.error("HTMLFileView.load filename=\(file.fileName) error=\(error.localizedDescription)")
        }
    }

    private func handleNavigation(_ navigation: HTMLFileNavigation, document: HTMLFileDocument) {
        guard case .loadingHTML(let currentDocument) = phase, currentDocument == document else { return }
        switch navigation {
        case .ready:
            phase = .ready(document)
        case .failed(let message):
            phase = .failed(message)
        }
    }
}

private struct HTMLFileLoadingView: View {
    private enum LabelVisibility {
        case hidden
        case visible
    }

    @State private var labelVisibility: LabelVisibility = .hidden

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            CellularAutomatonLoader()
            Text("Loading file…")
                .font(.subheadline)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .opacity(labelVisibility == .visible ? 1 : 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading file…"))
        .task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            withAnimation(Theme.Animation.standard) {
                labelVisibility = .visible
            }
        }
    }
}

nonisolated struct HTMLFileDocument: Hashable, Sendable {
    private static let contentSecurityPolicy = "default-src 'none'; img-src data: blob: ox-artifact:; media-src data: blob: ox-artifact:; script-src 'unsafe-inline'; style-src 'unsafe-inline'; font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; worker-src blob:; base-uri 'none'; form-action 'none'"

    let html: String
    let baseURL: URL
    let scope: ProfileScope?
    let byteCount: Int

    static func read(_ source: FilePreviewSource) async throws -> Self {
        guard source.file.kind == .html else { throw FileError.unsupportedType(source.file.fileName) }
        let baseURL = HTMLFilePage.documentURL(for: source)
        let data = try await source.read()
        guard data.count <= FileLimits.textBytes else {
            throw FileError.textTooLarge(bytes: data.count, limit: FileLimits.textBytes)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw FileError.textNotUTF8 }
        let secured = "<!doctype html><html><head><meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy)\"></head><body>\(text)</body></html>"
        return Self(
            html: secured,
            baseURL: baseURL,
            scope: source.scope,
            byteCount: data.count
        )
    }
}

@MainActor
private struct HTMLFileWebView: View {
    let document: HTMLFileDocument
    let safeAreaInsets: EdgeInsets
    let isReady: Bool
    let onNavigation: (HTMLFileNavigation) -> Void
    @State private var page: WebPage
    @State private var canvas: HTMLView
    @State private var presentations: AppPresentationCoordinator

    init(
        document: HTMLFileDocument,
        title: String,
        serviceManager: ServiceManager,
        safeAreaInsets: EdgeInsets,
        isReady: Bool,
        onNavigation: @escaping (HTMLFileNavigation) -> Void
    ) {
        self.document = document
        self.safeAreaInsets = safeAreaInsets
        self.isReady = isReady
        self.onNavigation = onNavigation
        let presentations = AppPresentationCoordinator()
        let canvas = HTMLView(title: title, serviceManager: serviceManager, presentations: presentations, messages: AppPresentations.live.messages)
        _presentations = State(initialValue: presentations)
        _canvas = State(initialValue: canvas)
        _page = State(initialValue: HTMLFilePage.make(scope: document.scope, canvas: canvas, documentURL: document.baseURL))
    }

    var body: some View {
        WebContentView(page: page, mode: .canvas)
            .opacity(isReady ? 1 : 0)
            .allowsHitTesting(isReady)
            .accessibilityHidden(!isReady)
            .task(id: document) { await load() }
            .onDisappear { canvas.close() }
            .safeAreaInset(edge: .bottom) {
                CanvasInteractionView(canvas: canvas)
            }
            .fullScreenCover(item: $canvas.browser) { browser in
                NavigationStack {
                    ServicePageInspector(service: browser.service, browserSessionID: browser.id)
                        .safeAreaInset(edge: .bottom) { CanvasInteractionView(canvas: canvas) }
                }
            }
            .appPresentations(presentations)
    }

    private func load() async {
        Log.ui.info("HTMLFileWebView.loading bytes=\(document.byteCount)")
        do {
            for try await event in page.load(html: document.html, baseURL: document.baseURL) {
                guard event == .finished else { continue }
                guard !Task.isCancelled else { return }
                onNavigation(.ready)
                Log.ui.info("HTMLFileWebView.ready safeAreaApplied=true safeArea=\(Int(safeAreaInsets.top))/\(Int(safeAreaInsets.trailing))/\(Int(safeAreaInsets.bottom))/\(Int(safeAreaInsets.leading))")
            }
        } catch is CancellationError {
            page.stopLoading()
        } catch {
            onNavigation(.failed(error.localizedDescription))
            Log.ui.error("HTMLFileWebView.navigation error=\(error.localizedDescription)")
        }
    }
}

private enum HTMLFileNavigation {
    case ready
    case failed(String)
}

@MainActor
enum HTMLFilePage {
    nonisolated static let resourceScheme = "ox-artifact"
    static let mapHandler = "oxMap"
    nonisolated static func documentURL(for source: FilePreviewSource) -> URL {
        guard let root = source.scope?.root.standardizedFileURL.pathComponents else { return CanvasWebBridge.documentURL }
        let path = source.file.fileURL.standardizedFileURL.pathComponents.dropFirst(root.count).joined(separator: "/")
        var components = URLComponents()
        components.scheme = resourceScheme
        components.path = "/" + path
        return components.url ?? CanvasWebBridge.documentURL
    }
    static let hostScript = #"""
        (() => {
          const denied = () => Promise.reject(new DOMException("Unavailable in this HTML file", "NotAllowedError"));
          try { Object.defineProperty(navigator, "geolocation", { value: undefined }); } catch (_) {}
          try { Object.defineProperty(navigator, "mediaDevices", { value: { getUserMedia: denied } }); } catch (_) {}
          class OxMap extends HTMLElement {
            async connectedCallback() {
              if (this.dataset.loading) return;
              this.dataset.loading = "true";
              const markers = Array.from(this.querySelectorAll("ox-marker")).slice(0, 50).map((node) => ({
                latitude: Number(node.getAttribute("latitude")),
                longitude: Number(node.getAttribute("longitude")),
                label: node.getAttribute("label") || ""
              }));
              const request = {
                latitude: Number(this.getAttribute("latitude")),
                longitude: Number(this.getAttribute("longitude")),
                radius: Number(this.getAttribute("radius") || 2000),
                markers
              };
              try {
                const result = await window.webkit.messageHandlers.oxMap.postMessage(request);
                const link = document.createElement("a");
                link.href = `https://maps.apple.com/?ll=${request.latitude},${request.longitude}`;
                link.setAttribute("aria-label", this.getAttribute("aria-label") || "Open map");
                const image = document.createElement("img");
                image.src = result.image;
                image.alt = this.getAttribute("aria-label") || "Map";
                image.style.cssText = "display:block;width:100%;height:auto;border-radius:16px";
                link.appendChild(image);
                this.replaceChildren(link);
              } catch (_) {
                this.textContent = "Map unavailable";
              }
            }
          }
          if (!customElements.get("ox-map")) customElements.define("ox-map", OxMap);
        })();
        """#

    static func make(scope: ProfileScope?, canvas: HTMLView, documentURL: URL) -> WebPage {
        let mapHandler = FileMapHandler()
        let contentController = WKUserContentController()
        contentController.addScriptMessageHandler(CanvasWebBridge(canvas: canvas, documentURL: documentURL), contentWorld: .page, name: "oxCanvas")
        do {
            contentController.addUserScript(WKUserScript(
                source: try CanvasServiceCatalog.script(documentID: canvas.id),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            ))
        } catch {
            Log.ui.error("Canvas.sdk unavailable error=\(error.localizedDescription)")
        }
        contentController.addScriptMessageHandler(mapHandler, contentWorld: .page, name: Self.mapHandler)
        contentController.addUserScript(WKUserScript(
            source: hostScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        ))
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultNavigationPreferences.allowsContentJavaScript = true
        configuration.userContentController = contentController
        let resourceHandler = FileResourceHandler(scope: scope)
        configuration.urlSchemeHandlers = [
            URLScheme(resourceScheme)!: resourceHandler,
        ]
        configuration.deviceSensorAuthorization = .init(decision: .deny)
        return WebPage(
            configuration: configuration,
            navigationDecider: FileNavigationDecider(documentURL: documentURL),
            dialogPresenter: RejectingFileDialogs()
        )
    }
}

private struct RejectingFileDialogs: WebPage.DialogPresenting {}

private struct FileNavigationDecider: WebPage.NavigationDeciding {
    let documentURL: URL
    private var admittedDocument = false

    init(documentURL: URL) { self.documentURL = documentURL }

    mutating func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if !admittedDocument, CanvasWebBridge.isDocumentURL(url, expected: documentURL) {
            admittedDocument = true
            return .allow
        }
        if action.navigationType == .linkActivated, CanvasWebBridge.isDocumentURL(url, expected: documentURL), url.fragment != nil {
            return .allow
        }
        if action.navigationType == .linkActivated,
           let scheme = url.scheme?.lowercased(),
           scheme == "https" || scheme == "http" || scheme == "mailto" || scheme == "tel" {
            await UIApplication.shared.open(url)
            Log.ui.info("HTMLFileWebView.external scheme=\(scheme) host=\(url.host ?? "")")
        } else {
            Log.ui.info("HTMLFileWebView.blocked scheme=\(url.scheme ?? "none")")
        }
        return .cancel
    }
}

private nonisolated struct FileResourceHandler: URLSchemeHandler, Sendable {
    let scope: ProfileScope?

    func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try Task.checkCancellation()
                    let (response, data, filename) = try await response(for: request)
                    try Task.checkCancellation()
                    continuation.yield(.response(response))
                    continuation.yield(.data(data))
                    continuation.finish()
                    Log.ui.info("HTMLFileResource.load filename=\(filename) bytes=\(data.count) status=\(response.statusCode)")
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                    Log.ui.error("HTMLFileResource.fail error=\(error.localizedDescription)")
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func response(for request: URLRequest) async throws -> (HTTPURLResponse, Data, String) {
        guard let url = request.url, url.scheme == HTMLFilePage.resourceScheme,
              let scope else { throw CocoaError(.fileReadNoPermission) }
        let name = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard url.host == nil, !name.isEmpty, !name.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw FileError.invalidFilename(name) }
        let type = UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension) ?? .data
        guard type.conforms(to: .image) || type.conforms(to: .audio) || type.conforms(to: .movie) else {
            throw FileError.unsupportedType(name)
        }
        let data = try await ProfileRepository.shared.readFileData(named: "/" + name, in: scope)
        let resource = try ResourceResponse(
            mimeType: type.preferredMIMEType ?? "application/octet-stream",
            data: data,
            rangeHeader: request.value(forHTTPHeaderField: "Range")
        )
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: resource.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: resource.headers
        ) else { throw FileError.unsupportedType(name) }
        return (response, resource.data, name)
    }
}

@MainActor
private final class FileMapHandler: NSObject, WKScriptMessageHandlerWithReply {
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        Task { @MainActor in
            do {
                let request = try MapRequest(message.body)
                let image = try await request.snapshot()
                replyHandler(["image": image], nil)
                Log.ui.info("HTMLFileMap.ready markers=\(request.markers.count) radius=\(Int(request.radius))")
            } catch {
                replyHandler(nil, error.localizedDescription)
                Log.ui.error("HTMLFileMap.fail error=\(error.localizedDescription)")
            }
        }
    }
}

private nonisolated struct ResourceResponse {
    let statusCode: Int
    let headers: [String: String]
    let data: Data

    init(mimeType: String, data: Data, rangeHeader: String?) throws {
        guard let rangeHeader else {
            statusCode = 200
            headers = [
                "Accept-Ranges": "bytes",
                "Content-Length": String(data.count),
                "Content-Type": mimeType
            ]
            self.data = data
            return
        }

        var lowerBound = 0
        var upperBound = data.count - 1
        guard data.isEmpty == false,
              rangeHeader.hasPrefix("bytes="),
              rangeHeader.dropFirst(6).contains(",") == false else {
            throw URLError(.badServerResponse)
        }
        let bounds = rangeHeader.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2 else { throw URLError(.badServerResponse) }
        if bounds[0].isEmpty {
            guard let suffixLength = Int(bounds[1]), suffixLength > 0 else { throw URLError(.badServerResponse) }
            lowerBound = max(data.count - suffixLength, 0)
        } else {
            guard let requestedLowerBound = Int(bounds[0]), requestedLowerBound >= 0, requestedLowerBound < data.count else {
                throw URLError(.badServerResponse)
            }
            lowerBound = requestedLowerBound
            if let requestedUpperBound = Int(bounds[1]) {
                guard requestedUpperBound >= lowerBound else { throw URLError(.badServerResponse) }
                upperBound = min(requestedUpperBound, data.count - 1)
            }
        }

        statusCode = 206
        self.data = data.subdata(in: lowerBound..<(upperBound + 1))
        headers = [
            "Accept-Ranges": "bytes",
            "Content-Length": String(self.data.count),
            "Content-Range": "bytes \(lowerBound)-\(upperBound)/\(data.count)",
            "Content-Type": mimeType
        ]
    }
}

private nonisolated struct MapRequest: Sendable {
    struct Marker: Sendable {
        let coordinate: CLLocationCoordinate2D
        let label: String
    }

    let center: CLLocationCoordinate2D
    let radius: CLLocationDistance
    let markers: [Marker]

    init(_ value: Any) throws {
        guard let object = value as? [String: Any],
              let latitude = object["latitude"] as? Double,
              let longitude = object["longitude"] as? Double,
              (-90...90).contains(latitude),
              (-180...180).contains(longitude) else {
            throw FileError.unsupportedType("map coordinates")
        }
        center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        radius = min(max(object["radius"] as? Double ?? 2_000, 100), 1_000_000)
        markers = (object["markers"] as? [[String: Any]] ?? []).prefix(50).compactMap { marker in
            guard let latitude = marker["latitude"] as? Double,
                  let longitude = marker["longitude"] as? Double,
                  (-90...90).contains(latitude),
                  (-180...180).contains(longitude) else { return nil }
            return Marker(
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                label: String((marker["label"] as? String ?? "").prefix(80))
            )
        }
    }

    @MainActor
    func snapshot() async throws -> String {
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: center,
            latitudinalMeters: radius * 2,
            longitudinalMeters: radius * 2
        )
        options.size = CGSize(width: 1_200, height: 720)
        options.scale = 1
        let snapshot = try await MKMapSnapshotter(options: options).start()
        let renderer = UIGraphicsImageRenderer(size: snapshot.image.size)
        let image = renderer.image { context in
            snapshot.image.draw(at: .zero)
            for marker in markers {
                let point = snapshot.point(for: marker.coordinate)
                guard CGRect(origin: .zero, size: snapshot.image.size).insetBy(dx: -20, dy: -20).contains(point) else { continue }
                let pin = CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20)
                context.cgContext.setFillColor(Theme.Colors.primary.uiColor.cgColor)
                context.cgContext.fillEllipse(in: pin)
                context.cgContext.setStrokeColor(UIColor.white.cgColor)
                context.cgContext.setLineWidth(3)
                context.cgContext.strokeEllipse(in: pin)
            }
        }
        guard let data = image.jpegData(compressionQuality: 0.85) else { throw FileError.imageEncodeFailed }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }
}
