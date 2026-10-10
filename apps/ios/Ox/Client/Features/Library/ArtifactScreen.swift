import PDFKit
import QuickLook
import SwiftUI
import UIKit

struct ArtifactZoomPreview: Identifiable, Hashable {
    let artifact: Artifact
    let sourceID: String
    let scope: ProfileScope?

    init(artifact: Artifact, sourceID: String, scope: ProfileScope? = StorageRoot.currentScope) {
        self.artifact = artifact
        self.sourceID = sourceID
        self.scope = scope
    }

    var id: String { sourceID }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sourceID == rhs.sourceID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(sourceID)
    }
}

private struct ArtifactPreviewNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var artifactPreviewNamespace: Namespace.ID? {
        get { self[ArtifactPreviewNamespaceKey.self] }
        set { self[ArtifactPreviewNamespaceKey.self] = newValue }
    }
}

private struct ArtifactPreviewTransitionSource: ViewModifier {
    let artifact: Artifact
    let sourceID: String?

    @Environment(\.artifactPreviewNamespace) private var namespace

    @ViewBuilder
    func body(content: Content) -> some View {
        if let sourceID, let namespace {
            content.matchedTransitionSource(id: sourceID, in: namespace) { source in
                source
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            }
        } else {
            content
        }
    }
}

extension View {
    func artifactPreviewTransitionSource(_ artifact: Artifact, sourceID: String?) -> some View {
        modifier(ArtifactPreviewTransitionSource(artifact: artifact, sourceID: sourceID))
    }
}

struct ArtifactScreen<Content: View>: View {
    let onDismiss: () -> Void
    let dismissIdentifier: String
    let content: (EdgeInsets) -> Content

    @ScaledMetric(relativeTo: .title3) private var iconButtonSize: CGFloat = 44

    init(
        onDismiss: @escaping () -> Void,
        dismissIdentifier: String,
        @ViewBuilder content: @escaping (EdgeInsets) -> Content
    ) {
        self.onDismiss = onDismiss
        self.dismissIdentifier = dismissIdentifier
        self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                Rectangle().fill(Theme.Colors.chatSurface)
                content(geometry.safeAreaInsets)
                    .padding(geometry.safeAreaInsets)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(Theme.Colors.onSurface)
                        .frame(width: iconButtonSize, height: iconButtonSize)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("Close file")
                .accessibilityIdentifier(dismissIdentifier)
                .padding(.top, geometry.safeAreaInsets.top + Theme.Spacing.sm)
                .padding(.trailing, Theme.Spacing.md)
            }
            .ignoresSafeArea()
        }
        .statusBarHidden(true)
    }
}

struct ArtifactNavigationPage: View {
    let artifact: Artifact
    let scope: ProfileScope?

    init(artifact: Artifact, scope: ProfileScope? = StorageRoot.currentScope) {
        self.artifact = artifact
        self.scope = scope
    }

    var body: some View {
        Group {
            if artifact.kind == .html {
                HTMLArtifactScreen(artifact: artifact, scope: scope)
            } else if artifact.isMarkdown {
                MarkdownArtifactScreen(artifact: artifact, scope: scope)
            }
        }
    }
}

struct ArtifactZoomPreviewScreen: View {
    enum Chrome {
        case immersive(onDismiss: () -> Void)
        case navigation
    }

    private enum LoadState: Equatable {
        case loading
        case ready
        case unavailable
    }

    let artifact: Artifact
    let chrome: Chrome
    private let source: ArtifactPreviewSource
    @State private var image: UIImage?
    @State private var pdfDocument: PDFDocument?
    @State private var snapshot: ArtifactPreviewSnapshot?
    @State private var previewURL: URL?
    @State private var loadState = LoadState.loading

    init(artifact: Artifact, chrome: Chrome, scope: ProfileScope? = StorageRoot.currentScope) {
        self.artifact = artifact
        self.chrome = chrome
        source = ArtifactPreviewSource(artifact: artifact, scope: scope)
    }

    @ViewBuilder
    var body: some View {
        Group {
            switch chrome {
            case .immersive(let onDismiss):
                ArtifactScreen(onDismiss: onDismiss, dismissIdentifier: A11yID.Artifacts.previewDismiss) { _ in
                    preview
                }
            case .navigation:
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.Colors.chatSurface)
                    .navigationTitle(artifact.userFacingName)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar(.visible, for: .navigationBar)
            }
        }
        .onAppear {
            Log.ui.info("ArtifactZoomPreviewScreen.load filename=\(artifact.fileName) kind=\(artifact.kind.rawValue)")
        }
        .task(id: artifact.fileURL) {
            await loadArtifact()
        }
        .quickLookPreview($previewURL)
    }

    @ViewBuilder
    private var preview: some View {
        switch artifact.kind {
        case .image:
            if let image, loadState == .ready {
                ZoomableImageView(image: image)
                    .accessibilityLabel(artifact.userFacingName)
                    .accessibilityIdentifier("artifacts.preview.ready")
            } else if loadState == .loading {
                loading
            } else {
                unavailable
            }
        case .pdf:
            if let pdfDocument, loadState == .ready {
                ZoomablePDFView(document: pdfDocument, accessibilityLabel: artifact.userFacingName)
            } else if loadState == .loading {
                loading
            } else {
                unavailable
            }
        case .text, .file:
            if let snapshot, loadState == .ready, QLPreviewController.canPreview(snapshot.url as NSURL) {
                Button {
                    previewURL = snapshot.url
                } label: {
                    Label("Open file", systemImage: "doc")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(artifact.userFacingName)
            } else if loadState == .loading {
                loading
            } else {
                unavailable
            }
        case .html:
            unavailable
        }
    }

    private var loading: some View {
        ContentLoadingView(label: "Loading file…")
            .accessibilityIdentifier("artifacts.preview.loading")
    }

    private var unavailable: some View {
        ContentUnavailableView(
            "File unavailable",
            systemImage: "questionmark.folder",
            description: Text(artifact.userFacingName)
        )
    }

    private func loadArtifact() async {
        image = nil
        pdfDocument = nil
        snapshot = nil
        loadState = .loading
        let started = ContinuousClock.now
        do {
            switch artifact.kind {
            case .image:
                let data = try await source.read()
                let loaded = await Task.detached(priority: .userInitiated) { UIImage(data: data) }.value
                try Task.checkCancellation()
                image = loaded
                loadState = loaded == nil ? .unavailable : .ready
            case .pdf:
                let data = try await source.read()
                let loaded = await Task.detached(priority: .userInitiated) { PDFDocument(data: data) }.value
                try Task.checkCancellation()
                pdfDocument = loaded
                loadState = loaded == nil ? .unavailable : .ready
            case .text, .file:
                let loaded = try await source.snapshot()
                snapshot = loaded
                loadState = .ready
                if QLPreviewController.canPreview(loaded.url as NSURL) { previewURL = loaded.url }
            case .html:
                loadState = .unavailable
            }
        } catch is CancellationError {
            return
        } catch {
            loadState = .unavailable
            Log.ui.error("ArtifactZoomPreviewScreen.read file=\(artifact.fileName) error=\(error.localizedDescription)")
        }
        Log.ui.info("ArtifactZoomPreviewScreen.ready filename=\(artifact.fileName) kind=\(artifact.kind.rawValue) success=\(loadState == .ready) elapsed=\(ContinuousClock.now - started)")
    }
}

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomingImageScrollView {
        ZoomingImageScrollView(image: image)
    }

    func updateUIView(_ view: ZoomingImageScrollView, context: Context) {
        view.setImage(image)
    }
}

final class ZoomingImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var laidOutSize = CGSize.zero

    init(image: UIImage) {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 8
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        setImage(image)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setImage(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        laidOutSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = imageView.image, bounds.width > 0, bounds.height > 0 else { return }
        if laidOutSize != bounds.size {
            laidOutSize = bounds.size
            setZoomScale(minimumZoomScale, animated: false)
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            imageView.frame = CGRect(origin: .zero, size: size)
            contentSize = size
        }
        centerContent()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
    }

    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let scale = min(maximumZoomScale, 3)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        let point = gesture.location(in: imageView)
        zoom(to: CGRect(
            x: point.x - size.width / 2,
            y: point.y - size.height / 2,
            width: size.width,
            height: size.height
        ), animated: true)
    }

    private func centerContent() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }
}

private struct ZoomablePDFView: UIViewRepresentable {
    let document: PDFDocument
    let accessibilityLabel: String

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "artifacts.preview.ready"
        view.accessibilityLabel = accessibilityLabel
        view.autoScales = true
        view.displayDirection = .vertical
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.backgroundColor = Theme.Colors.chatSurface.uiColor
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
        view.accessibilityLabel = accessibilityLabel
    }
}
