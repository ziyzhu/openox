import Observation
import SwiftUI
import WebKit

@MainActor
@Observable
private final class InlineCanvasSession {
    enum Phase {
        case loading
        case ready
        case failed(String)
    }

    let page: WebPage
    let canvas: OxCanvas
    let presentations: AppPresentationCoordinator
    let source: ArtifactPreviewSource
    private(set) var phase: Phase = .loading

    init(source: ArtifactPreviewSource, serviceManager: ServiceManager) {
        let artifact = source.artifact
        self.source = source
        let presentations = AppPresentationCoordinator()
        let canvas = OxCanvas(title: artifact.userFacingName, serviceManager: serviceManager, presentations: presentations)
        self.presentations = presentations
        self.canvas = canvas
        page = HTMLArtifactPage.make(scope: source.scope, canvas: canvas)
    }

    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    func load() async {
        let artifact = source.artifact
        do {
            let document = try await HTMLArtifactDocument.read(source)
            try Task.checkCancellation()
            Log.ui.info("InlineCanvas.loading filename=\(artifact.fileName) bytes=\(document.byteCount)")
            for try await event in page.load(html: document.html, baseURL: HTMLArtifactPage.baseURL) {
                guard event == .finished else { continue }
                try Task.checkCancellation()
                phase = .ready
                Log.ui.info("InlineCanvas.ready filename=\(artifact.fileName)")
            }
        } catch is CancellationError {
            page.stopLoading()
        } catch {
            phase = .failed(artifact.userFacingErrorDescription(error))
            Log.ui.error("InlineCanvas.failed filename=\(artifact.fileName) error=\(error.localizedDescription)")
        }
    }

    func close() {
        page.stopLoading()
        canvas.close()
    }
}

struct InlineCanvasCard: View {
    let artifact: Artifact
    let rowID: UUID
    private let source: ArtifactPreviewSource

    init(artifact: Artifact, rowID: UUID, scope: ProfileScope? = StorageRoot.currentScope) {
        self.artifact = artifact
        self.rowID = rowID
        source = ArtifactPreviewSource(artifact: artifact, scope: scope)
    }

    @Environment(ServiceManager.self) private var serviceManager
    @State private var session: InlineCanvasSession?
    @State private var loadedModifiedAt: Date?
    @State private var pageMount = WebPageMountCoordinator()
    @State private var isPresented = false

    var body: some View {
        Group {
            if let session, !isPresented {
                InlineCanvasPageCard(
                    artifact: artifact,
                    session: session,
                    rowID: rowID,
                    pageMount: pageMount,
                    expand: { Task { await expand(session) } }
                )
                .appPresentations(session.presentations)
            } else {
                LivePageCard(
                    service: nil,
                    fallbackSystemImage: "square.on.square",
                    title: artifact.userFacingName,
                    subtitle: String(localized: "Canvas"),
                    mount: nil,
                    inlinePageAnchorID: nil,
                    isPresented: isPresented,
                    placeholder: .progress(String(localized: "Loading canvas…")),
                    activate: nil,
                    expand: nil,
                    cancel: nil,
                    accessibilityIdentifier: A11yID.Chat.Message.artifact(artifact.id),
                    expandAccessibilityIdentifier: A11yID.Chat.canvasExpand(artifact.id),
                    cancelAccessibilityIdentifier: ""
                )
            }
        }
        .fullScreenCover(isPresented: $isPresented, onDismiss: restore) {
            if let session {
                InlineCanvasExpandedView(artifact: artifact, session: session) {
                    isPresented = false
                }
                .appPresentations(session.presentations)
            }
        }
        .task(id: artifact.modifiedAt) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .artifactChanged)) { notification in
            guard let fileURL = notification.object as? URL, fileURL == artifact.fileURL else { return }
            Task { await load() }
        }
        .onDisappear {
            guard !isPresented,
                  session?.canvas.browser == nil,
                  session?.presentations.presented == nil else { return }
            session?.close()
            session = nil
            pageMount.clear()
        }
    }

    private func load() async {
        guard !isPresented else { return }
        let modifiedAt = artifact.modifiedAt
        guard session == nil || loadedModifiedAt != modifiedAt else { return }
        session?.close()
        pageMount.clear()
        loadedModifiedAt = modifiedAt
        let loaded = InlineCanvasSession(source: source, serviceManager: serviceManager)
        session = loaded
        await loaded.load()
        guard !Task.isCancelled, session === loaded, loaded.isReady else { return }
        pageMount.reconcile(page: loaded.page, ownerIDs: [rowID])
    }

    private func expand(_ loaded: InlineCanvasSession) async {
        guard session === loaded, loaded.isReady,
              await pageMount.detach(page: loaded.page, ownerID: rowID) else { return }
        isPresented = true
        Log.ui.info("InlineCanvas.expand filename=\(artifact.fileName)")
    }

    private func restore() {
        guard let session else { return }
        pageMount.restore(page: session.page, ownerID: rowID)
        if loadedModifiedAt != artifact.modifiedAt {
            Task { await load() }
        }
        Log.ui.info("InlineCanvas.restore filename=\(artifact.fileName)")
    }
}

private struct InlineCanvasPageCard: View {
    let artifact: Artifact
    let session: InlineCanvasSession
    let rowID: UUID
    let pageMount: WebPageMountCoordinator
    let expand: () -> Void
    @Bindable private var canvas: OxCanvas

    init(artifact: Artifact, session: InlineCanvasSession, rowID: UUID, pageMount: WebPageMountCoordinator, expand: @escaping () -> Void) {
        self.artifact = artifact
        self.session = session
        self.rowID = rowID
        self.pageMount = pageMount
        self.expand = expand
        canvas = session.canvas
    }

    var body: some View {
        VStack(spacing: 0) {
            LivePageCard(
                service: nil,
                fallbackSystemImage: "square.on.square",
                title: artifact.userFacingName,
                subtitle: String(localized: "Canvas"),
                mount: session.isReady && pageMount.isInline(page: session.page, ownerID: rowID)
                    ? WebPageMount(page: session.page, ownerID: rowID, coordinator: pageMount)
                    : nil,
                inlinePageAnchorID: nil,
                isPresented: false,
                placeholder: placeholder,
                activate: nil,
                expand: session.isReady ? expand : nil,
                cancel: nil,
                accessibilityIdentifier: A11yID.Chat.Message.artifact(artifact.id),
                expandAccessibilityIdentifier: A11yID.Chat.canvasExpand(artifact.id),
                cancelAccessibilityIdentifier: "",
                webContentMode: .canvas,
                expandAccessibilityLabel: String(localized: "Expand canvas")
            )
            CanvasInteractionView(canvas: canvas)
        }
        .fullScreenCover(item: $canvas.browser) { browser in
            NavigationStack {
                ServicePageInspector(service: browser.service, browserSessionID: browser.id)
                    .safeAreaInset(edge: .bottom) { CanvasInteractionView(canvas: canvas) }
            }
        }
    }

    private var placeholder: LivePageCard.Placeholder {
        switch session.phase {
        case .loading, .ready: .progress(String(localized: "Loading canvas…"))
        case .failed(let message): .unavailable(message)
        }
    }
}

private struct InlineCanvasExpandedView: View {
    let artifact: Artifact
    let session: InlineCanvasSession
    let dismiss: () -> Void
    @Bindable private var canvas: OxCanvas

    init(artifact: Artifact, session: InlineCanvasSession, dismiss: @escaping () -> Void) {
        self.artifact = artifact
        self.session = session
        self.dismiss = dismiss
        canvas = session.canvas
    }

    var body: some View {
        NavigationStack {
            WebContentView(page: session.page, mode: .canvas)
                .background(Theme.Colors.chatSurface)
                .safeAreaInset(edge: .bottom) { CanvasInteractionView(canvas: canvas) }
                .navigationTitle(artifact.userFacingName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done", action: dismiss)
                            .accessibilityIdentifier(A11yID.ServiceInspector.close)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        ArtifactShareButton(artifact: artifact, scope: session.source.scope) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel(A11yLabel.shareArtifact)
                        .accessibilityIdentifier(A11yID.Artifacts.share(artifact.id))
                    }
                }
        }
        .fullScreenCover(item: $canvas.browser) { browser in
            NavigationStack {
                ServicePageInspector(service: browser.service, browserSessionID: browser.id)
                    .safeAreaInset(edge: .bottom) { CanvasInteractionView(canvas: canvas) }
            }
        }
    }
}
