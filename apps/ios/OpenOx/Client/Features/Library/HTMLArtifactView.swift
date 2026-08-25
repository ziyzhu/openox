import MapKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct HTMLArtifactScreen: View {
    let artifact: Artifact

    var body: some View {
        GeometryReader { geometry in
            HTMLArtifactView(
                artifact: artifact,
                modifiedAt: artifact.modifiedAt,
                safeAreaInsets: geometry.safeAreaInsets
            )
        }
        .background(Theme.Colors.chatSurface)
        .navigationTitle(artifact.userFacingName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: artifact.fileURL) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel(A11yLabel.shareArtifact)
                .accessibilityIdentifier(A11yID.Artifacts.share(artifact.id))
            }
        }
    }
}

struct HTMLArtifactView: View {
    let artifact: Artifact
    let modifiedAt: Date?
    let safeAreaInsets: EdgeInsets

    private enum Phase {
        case loadingFile
        case loadingHTML(HTMLArtifactDocument)
        case ready(HTMLArtifactDocument)
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

    @State private var phase: Phase = .loadingFile

    var body: some View {
        ZStack {
            switch phase {
            case .loadingFile:
                Color.clear
            case .loadingHTML(let document), .ready(let document):
                HTMLArtifactWebView(
                    document: document,
                    safeAreaInsets: safeAreaInsets,
                    isReady: phase.isReady,
                    onNavigation: { handleNavigation($0, document: document) }
                )
            case .failed(let message):
                ContentUnavailableView(
                    "Artifact unavailable",
                    systemImage: artifact.exists ? "exclamationmark.triangle" : "questionmark.folder",
                    description: Text(message)
                )
            }
            if phase.isLoading {
                HTMLArtifactLoadingView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.chatSurface)
        .task(id: modifiedAt) { await load() }
    }

    private func load() async {
        phase = .loadingFile
        do {
            let document = try await Task.detached(priority: .userInitiated) {
                try HTMLArtifactDocument.read(artifact)
            }.value
            guard !Task.isCancelled else { return }
            phase = .loadingHTML(document)
            Log.ui.info("HTMLArtifactView.load filename=\(artifact.fileName) bytes=\(document.byteCount)")
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(artifact.userFacingErrorDescription(error))
            Log.ui.error("HTMLArtifactView.load filename=\(artifact.fileName) error=\(error.localizedDescription)")
        }
    }

    private func handleNavigation(_ navigation: HTMLArtifactNavigation, document: HTMLArtifactDocument) {
        guard case .loadingHTML(let currentDocument) = phase, currentDocument == document else { return }
        switch navigation {
        case .ready:
            phase = .ready(document)
        case .failed(let message):
            phase = .failed(message)
        }
    }
}

private struct HTMLArtifactLoadingView: View {
    private enum LabelVisibility {
        case hidden
        case visible
    }

    @State private var labelVisibility: LabelVisibility = .hidden

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            CellularAutomatonLoader()
            Text("Loading artifact…")
                .font(.subheadline)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .opacity(labelVisibility == .visible ? 1 : 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading artifact…"))
        .task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                labelVisibility = .visible
            }
        }
    }
}

nonisolated struct HTMLArtifactDocument: Equatable, Sendable {
    private static let contentSecurityPolicy = "default-src 'none'; img-src data: blob: ox-artifact:; media-src data: blob: ox-artifact:; script-src 'unsafe-inline'; style-src 'unsafe-inline'; font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; worker-src blob:; base-uri 'none'; form-action 'none'"

    let html: String
    let directory: URL
    let byteCount: Int

    static func read(_ artifact: Artifact) throws -> Self {
        guard artifact.kind == .html else { throw ArtifactError.unsupportedType(artifact.fileName) }
        guard artifact.exists else { throw ArtifactError.missing(artifact.fileName) }
        let data = try Data(contentsOf: artifact.fileURL)
        guard data.count <= ArtifactLimits.textBytes else {
            throw ArtifactError.textTooLarge(bytes: data.count, limit: ArtifactLimits.textBytes)
        }
        guard let source = String(data: data, encoding: .utf8) else { throw ArtifactError.textNotUTF8 }
        let secured = "<!doctype html><html><head><meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy)\"></head><body>\(source)</body></html>"
        return Self(
            html: secured,
            directory: artifact.fileURL.deletingLastPathComponent(),
            byteCount: data.count
        )
    }
}

@MainActor
private struct HTMLArtifactWebView: View {
    let document: HTMLArtifactDocument
    let safeAreaInsets: EdgeInsets
    let isReady: Bool
    let onNavigation: (HTMLArtifactNavigation) -> Void
    @State private var page: WebPage

    init(
        document: HTMLArtifactDocument,
        safeAreaInsets: EdgeInsets,
        isReady: Bool,
        onNavigation: @escaping (HTMLArtifactNavigation) -> Void
    ) {
        self.document = document
        self.safeAreaInsets = safeAreaInsets
        self.isReady = isReady
        self.onNavigation = onNavigation
        _page = State(initialValue: HTMLArtifactPage.make(directory: document.directory))
    }

    var body: some View {
        WebView(page)
            .webViewBackForwardNavigationGestures(.disabled)
            .webViewElementFullscreenBehavior(.enabled)
            .opacity(isReady ? 1 : 0)
            .allowsHitTesting(isReady)
            .accessibilityHidden(!isReady)
            .task(id: document) { await load() }
    }

    private func load() async {
        Log.ui.info("HTMLArtifactWebView.loading bytes=\(document.byteCount)")
        do {
            for try await event in page.load(html: document.html, baseURL: HTMLArtifactPage.baseURL) {
                guard event == .finished else { continue }
                guard !Task.isCancelled else { return }
                onNavigation(.ready)
                Log.ui.info("HTMLArtifactWebView.ready safeAreaApplied=true safeArea=\(Int(safeAreaInsets.top))/\(Int(safeAreaInsets.trailing))/\(Int(safeAreaInsets.bottom))/\(Int(safeAreaInsets.leading))")
            }
        } catch is CancellationError {
            page.stopLoading()
        } catch {
            onNavigation(.failed(error.localizedDescription))
            Log.ui.error("HTMLArtifactWebView.navigation error=\(error.localizedDescription)")
        }
    }
}

private enum HTMLArtifactNavigation {
    case ready
    case failed(String)
}

@MainActor
private enum HTMLArtifactPage {
    static let resourceScheme = "ox-artifact"
    static let mapHandler = "oxMap"
    static let baseURL = URL(string: "\(resourceScheme):///")!
    static let hostScript = #"""
        (() => {
          const denied = () => Promise.reject(new DOMException("Unavailable in an artifact", "NotAllowedError"));
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

    static func make(directory: URL) -> WebPage {
        let mapHandler = ArtifactMapHandler()
        let contentController = WKUserContentController()
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
        let resourceHandler = ArtifactResourceHandler(directory: directory)
        configuration.urlSchemeHandlers = [
            URLScheme(resourceScheme)!: resourceHandler,
        ]
        configuration.deviceSensorAuthorization = .init(decision: .deny)
        return WebPage(
            configuration: configuration,
            navigationDecider: ArtifactNavigationDecider(),
            dialogPresenter: RejectingArtifactDialogs()
        )
    }
}

private struct RejectingArtifactDialogs: WebPage.DialogPresenting {}

private struct ArtifactNavigationDecider: WebPage.NavigationDeciding {
    mutating func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if url.scheme == HTMLArtifactPage.resourceScheme || url.scheme == "about" { return .allow }
        if action.navigationType == .linkActivated,
           let scheme = url.scheme?.lowercased(),
           scheme == "https" || scheme == "http" || scheme == "mailto" || scheme == "tel" {
            await UIApplication.shared.open(url)
            Log.ui.info("HTMLArtifactWebView.external scheme=\(scheme) host=\(url.host ?? "")")
        } else {
            Log.ui.info("HTMLArtifactWebView.blocked scheme=\(url.scheme ?? "none")")
        }
        return .cancel
    }
}

private nonisolated struct ArtifactResourceHandler: URLSchemeHandler, Sendable {
    let directory: URL

    func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try Task.checkCancellation()
                    let (response, data, filename) = try response(for: request)
                    try Task.checkCancellation()
                    continuation.yield(.response(response))
                    continuation.yield(.data(data))
                    continuation.finish()
                    Log.ui.info("HTMLArtifactResource.load filename=\(filename) bytes=\(data.count) status=\(response.statusCode)")
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                    Log.ui.error("HTMLArtifactResource.fail error=\(error.localizedDescription)")
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func response(for request: URLRequest) throws -> (HTTPURLResponse, Data, String) {
        guard let url = request.url else { throw ArtifactError.invalidFilename("") }
        let name = try ArtifactStore.validatedFilename(url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
        guard let existing = ArtifactStore.existingFilename(matching: name, in: directory) else {
            throw ArtifactError.missing(name)
        }
        let file = directory.appendingPathComponent(existing, isDirectory: false)
        let type = UTType(filenameExtension: file.pathExtension) ?? .data
        guard type.conforms(to: .image) || type.conforms(to: .audio) || type.conforms(to: .movie) else {
            throw ArtifactError.unsupportedType(existing)
        }
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw ArtifactError.missing(existing) }
        let byteCount = values.fileSize ?? 0
        guard byteCount <= ArtifactLimits.fileBytes else {
            throw ArtifactError.fileTooLarge(bytes: byteCount, limit: ArtifactLimits.fileBytes)
        }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
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
        ) else { throw ArtifactError.unsupportedType(existing) }
        return (response, resource.data, existing)
    }
}

@MainActor
private final class ArtifactMapHandler: NSObject, WKScriptMessageHandlerWithReply {
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
                Log.ui.info("HTMLArtifactMap.ready markers=\(request.markers.count) radius=\(Int(request.radius))")
            } catch {
                replyHandler(nil, error.localizedDescription)
                Log.ui.error("HTMLArtifactMap.fail error=\(error.localizedDescription)")
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
            throw ArtifactError.unsupportedType("map coordinates")
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
        guard let data = image.jpegData(compressionQuality: 0.85) else { throw ArtifactError.imageEncodeFailed }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }
}
