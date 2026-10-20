import PDFKit
import QuickLook
import SwiftUI
import UIKit

struct FileZoomPreview: Identifiable, Hashable {
    let file: FileItem
    let sourceID: String
    let scope: ProfileScope?

    init(file: FileItem, sourceID: String, scope: ProfileScope? = StorageRoot.currentScope) {
        self.file = file
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

private struct FilePreviewNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var filePreviewNamespace: Namespace.ID? {
        get { self[FilePreviewNamespaceKey.self] }
        set { self[FilePreviewNamespaceKey.self] = newValue }
    }
}

private struct FilePreviewTransitionSource: ViewModifier {
    let file: FileItem
    let sourceID: String?

    @Environment(\.filePreviewNamespace) private var namespace

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
    func filePreviewTransitionSource(_ file: FileItem, sourceID: String?) -> some View {
        modifier(FilePreviewTransitionSource(file: file, sourceID: sourceID))
    }
}

struct FileScreen<Content: View, Actions: View>: View {
    let onDismiss: () -> Void
    let dismissIdentifier: String
    let content: (EdgeInsets) -> Content
    let actions: () -> Actions

    @ScaledMetric(relativeTo: .title3) private var iconButtonSize: CGFloat = 44

    init(
        onDismiss: @escaping () -> Void,
        dismissIdentifier: String,
        @ViewBuilder content: @escaping (EdgeInsets) -> Content,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.onDismiss = onDismiss
        self.dismissIdentifier = dismissIdentifier
        self.content = content
        self.actions = actions
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Rectangle().fill(Theme.Colors.conversationSurface)
                content(geometry.safeAreaInsets)
                    .padding(geometry.safeAreaInsets)
                HStack(spacing: Theme.Spacing.sm) {
                    closeButton
                    Spacer()
                    actions()
                }
                .padding(.top, geometry.safeAreaInsets.top + Theme.Spacing.sm)
                .padding(.horizontal, Theme.Spacing.md)
            }
            .ignoresSafeArea()
        }
        .statusBarHidden(true)
    }

    private var closeButton: some View {
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
    }
}

extension FileScreen where Actions == EmptyView {
    init(
        onDismiss: @escaping () -> Void,
        dismissIdentifier: String,
        @ViewBuilder content: @escaping (EdgeInsets) -> Content
    ) {
        self.init(onDismiss: onDismiss, dismissIdentifier: dismissIdentifier, content: content) { EmptyView() }
    }
}

struct FileNavigationPage: View {
    let file: FileItem
    let scope: ProfileScope?

    init(file: FileItem, scope: ProfileScope? = StorageRoot.currentScope) {
        self.file = file
        self.scope = scope
    }

    var body: some View {
        Group {
            if file.kind == .html {
                HTMLFileScreen(file: file, scope: scope)
            } else if file.isMarkdown {
                MarkdownFileScreen(file: file, scope: scope)
            }
        }
    }
}

struct FileZoomPreviewScreen: View {
    enum Chrome {
        case immersive(onDismiss: () -> Void)
        case navigation
    }

    private enum LoadState: Equatable {
        case loading
        case ready
        case unavailable
    }

    let file: FileItem
    let chrome: Chrome
    private let source: FilePreviewSource
    @State private var image: UIImage?
    @State private var pdfDocument: PDFDocument?
    @State private var snapshot: FilePreviewSnapshot?
    @State private var previewURL: URL?
    @State private var loadState = LoadState.loading
    @State private var closesWithQuickLook = false
    @Environment(\.dismiss) private var dismiss

    init(file: FileItem, chrome: Chrome, scope: ProfileScope? = StorageRoot.currentScope) {
        self.file = file
        self.chrome = chrome
        source = FilePreviewSource(file: file, scope: scope)
    }

    @ViewBuilder
    var body: some View {
        Group {
            switch chrome {
            case .immersive(let onDismiss):
                FileScreen(onDismiss: onDismiss, dismissIdentifier: A11yID.Files.previewDismiss) { _ in
                    preview
                }
            case .navigation:
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.Colors.conversationSurface)
                    .navigationTitle(file.userFacingName)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar(.visible, for: .navigationBar)
            }
        }
        .onAppear {
            Log.ui.info("FileZoomPreviewScreen.load filename=\(file.fileName) kind=\(file.kind.rawValue)")
        }
        .task(id: file.fileURL) {
            await loadFile()
        }
        .quickLookPreview($previewURL)
        .onChange(of: previewURL) { previous, current in
            guard previous != nil, current == nil, closesWithQuickLook else { return }
            switch chrome {
            case .immersive(let onDismiss): onDismiss()
            case .navigation: dismiss()
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch file.kind {
        case .image:
            imagePreview
        case .pdf:
            if let pdfDocument, loadState == .ready {
                ZoomablePDFView(document: pdfDocument, accessibilityLabel: file.userFacingName)
            } else if loadState == .loading {
                loading
            } else {
                unavailable
            }
        case .text, .file:
            if file.isSVG {
                imagePreview
            } else if let snapshot, loadState == .ready {
                openFileButton(snapshot)
            } else if loadState == .loading {
                loading
            } else {
                unavailable
            }
        case .html:
            unavailable
        }
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let image, loadState == .ready {
            ZoomableImageView(image: image)
                .accessibilityLabel(file.userFacingName)
                .accessibilityIdentifier("files.preview.ready")
        } else if loadState == .loading {
            loading
        } else {
            unavailable
        }
    }

    @ViewBuilder
    private func openFileButton(_ snapshot: FilePreviewSnapshot) -> some View {
        if QLPreviewController.canPreview(snapshot.url as NSURL) {
            Button {
                previewURL = snapshot.url
            } label: {
                Label("Open file", systemImage: "doc")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(file.userFacingName)
        } else {
            unavailable
        }
    }

    private var loading: some View {
        ContentLoadingView(label: "Loading file…")
            .accessibilityIdentifier("files.preview.loading")
    }

    private var unavailable: some View {
        ContentUnavailableView(
            "File unavailable",
            systemImage: "questionmark.folder",
            description: Text(file.userFacingName)
        )
    }

    private func loadSnapshot() async throws {
        let loaded = try await source.snapshot()
        try Task.checkCancellation()
        snapshot = loaded
        loadState = .ready
        guard QLPreviewController.canPreview(loaded.url as NSURL) else { return }
        closesWithQuickLook = true
        previewURL = loaded.url
    }

    private func loadSVG() async throws {
        let loaded = try await WebSnapshot.image(svg: source.read(), width: 800)
        try Task.checkCancellation()
        image = loaded
        loadState = .ready
    }

    private func loadFile() async {
        image = nil
        pdfDocument = nil
        snapshot = nil
        loadState = .loading
        let started = ContinuousClock.now
        do {
            switch file.kind {
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
                if file.isSVG { try await loadSVG() } else { try await loadSnapshot() }
            case .html:
                loadState = .unavailable
            }
        } catch is CancellationError {
            return
        } catch {
            loadState = .unavailable
            Log.ui.error("FileZoomPreviewScreen.read file=\(file.fileName) error=\(error.localizedDescription)")
        }
        Log.ui.info("FileZoomPreviewScreen.ready filename=\(file.fileName) kind=\(file.kind.rawValue) success=\(loadState == .ready) elapsed=\(ContinuousClock.now - started)")
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
        view.accessibilityIdentifier = "files.preview.ready"
        view.accessibilityLabel = accessibilityLabel
        view.autoScales = true
        view.displayDirection = .vertical
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.backgroundColor = Theme.Colors.conversationSurface.uiColor
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
        view.accessibilityLabel = accessibilityLabel
    }
}
