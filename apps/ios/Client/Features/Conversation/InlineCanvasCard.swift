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
    let canvas: HTMLView
    let presentations: AppPresentationCoordinator
    let source: FilePreviewSource
    private(set) var phase: Phase = .loading
    private(set) var contentHeight: CGFloat?

    private static let contentHeightScript = """
        const measure = () => {
          const body = document.body;
          if (!body) return 0;
          const rect = body.getBoundingClientRect();
          const bottom = parseFloat(getComputedStyle(body).marginBottom) || 0;
          return Math.ceil(rect.top + window.scrollY + Math.max(rect.height, body.scrollHeight) + bottom);
        };
        const current = measure();
        if (current !== known) return current;
        return await new Promise((resolve) => {
          const observer = new ResizeObserver(() => {
            const next = measure();
            if (next === known) return;
            observer.disconnect();
            resolve(next);
          });
          observer.observe(document.documentElement);
          if (document.body) observer.observe(document.body);
        });
        """

    init(source: FilePreviewSource, serviceManager: ServiceManager) {
        let file = source.file
        self.source = source
        let presentations = AppPresentationCoordinator()
        let canvas = HTMLView(title: file.userFacingName, serviceManager: serviceManager, presentations: presentations, messages: AppPresentations.live.messages)
        self.presentations = presentations
        self.canvas = canvas
        page = HTMLFilePage.make(scope: source.scope, canvas: canvas, documentURL: HTMLFilePage.documentURL(for: source))
    }

    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    func load() async {
        let file = source.file
        do {
            let document = try await HTMLFileDocument.read(source)
            try Task.checkCancellation()
            Log.ui.info("InlineCanvas.loading filename=\(file.fileName) bytes=\(document.byteCount)")
            for try await event in page.load(html: document.html, baseURL: document.baseURL) {
                guard event == .finished else { continue }
                try Task.checkCancellation()
                phase = .ready
                Log.ui.info("InlineCanvas.ready filename=\(file.fileName)")
            }
        } catch is CancellationError {
            page.stopLoading()
        } catch {
            phase = .failed(error.localizedDescription)
            Log.ui.error("InlineCanvas.failed filename=\(file.fileName) error=\(error.localizedDescription)")
        }
    }

    func trackContentHeight() async {
        while !Task.isCancelled {
            guard let value = try? await page.callJavaScript(
                Self.contentHeightScript,
                arguments: ["known": Double(contentHeight ?? -1)],
                in: nil,
                contentWorld: .defaultClient
            ) as? Double, !Task.isCancelled else { return }
            contentHeight = CGFloat(value)
            Log.ui.debug("InlineCanvas.contentHeight filename=\(source.file.fileName) height=\(Int(value))")
        }
    }

    func close() {
        page.stopLoading()
        canvas.close()
    }
}

struct InlineCanvasCard: View {
    let file: FileItem
    let rowID: UUID
    private let source: FilePreviewSource

    init(file: FileItem, rowID: UUID, scope: ProfileScope? = StorageRoot.currentScope) {
        self.file = file
        self.rowID = rowID
        source = FilePreviewSource(file: file, scope: scope)
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
                    file: file,
                    session: session,
                    rowID: rowID,
                    pageMount: pageMount,
                    expand: { Task { await expand(session) } }
                )
                .appPresentations(session.presentations)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    InlineCanvasPlaceholder(message: String(localized: "Loading HTML…"), isFailure: false)
                        .accessibilityIdentifier(A11yID.ConversationControls.Message.file(file.id))
                    InlineCanvasFileLink(file: file, open: nil)
                }
            }
        }
        .fullScreenCover(isPresented: $isPresented, onDismiss: restore) {
            if let session {
                InlineCanvasExpandedView(file: file, session: session) {
                    isPresented = false
                }
                .appPresentations(session.presentations)
            }
        }
        .task(id: file.modifiedAt) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .fileChanged)) { notification in
            guard let fileURL = notification.object as? URL, fileURL == file.fileURL else { return }
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
        let modifiedAt = file.modifiedAt
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
        Log.ui.info("InlineCanvas.expand filename=\(file.fileName)")
    }

    private func restore() {
        guard let session else { return }
        pageMount.restore(page: session.page, ownerID: rowID)
        if loadedModifiedAt != file.modifiedAt {
            Task { await load() }
        }
        Log.ui.info("InlineCanvas.restore filename=\(file.fileName)")
    }
}

private struct InlineCanvasPageCard: View {
    let file: FileItem
    let session: InlineCanvasSession
    let rowID: UUID
    let pageMount: WebPageMountCoordinator
    let expand: () -> Void
    @Bindable private var canvas: HTMLView

    init(file: FileItem, session: InlineCanvasSession, rowID: UUID, pageMount: WebPageMountCoordinator, expand: @escaping () -> Void) {
        self.file = file
        self.session = session
        self.rowID = rowID
        self.pageMount = pageMount
        self.expand = expand
        canvas = session.canvas
    }

    private static let maximumHeight: CGFloat = 720

    private var mount: WebPageMount? {
        guard session.isReady, pageMount.isInline(page: session.page, ownerID: rowID) else { return nil }
        return WebPageMount(page: session.page, ownerID: rowID, coordinator: pageMount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(A11yID.ConversationControls.Message.file(file.id))
            InlineCanvasFileLink(file: file, open: session.isReady ? expand : nil)
            CanvasInteractionView(canvas: canvas)
        }
        .animation(.spring(duration: 0.3, bounce: 0), value: session.contentHeight)
        .task(id: mount != nil) {
            guard mount != nil else { return }
            await session.trackContentHeight()
        }
        .fullScreenCover(item: $canvas.browser) { browser in
            NavigationStack {
                ServicePageInspector(service: browser.service, browserSessionID: browser.id)
                    .safeAreaInset(edge: .bottom) { CanvasInteractionView(canvas: canvas) }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let mount {
            MountedWebPageView(mount: mount, mode: .canvas)
                .frame(height: min(session.contentHeight ?? InlineCanvasPlaceholder.height, Self.maximumHeight))
        } else if case .failed(let message) = session.phase {
            InlineCanvasPlaceholder(message: message, isFailure: true)
        } else {
            InlineCanvasPlaceholder(message: String(localized: "Loading HTML…"), isFailure: false)
        }
    }
}

private struct InlineCanvasFileLink: View {
    let file: FileItem
    let open: (() -> Void)?

    var body: some View {
        Button {
            open?()
        } label: {
            Text(file.userFacingName)
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurface)
                .underline(pattern: .dot)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minHeight: Theme.Size.minimumTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(open == nil)
        .accessibilityHint(String(localized: "Open HTML"))
        .accessibilityIdentifier(A11yID.ConversationControls.canvasExpand(file.id))
    }
}

private struct InlineCanvasPlaceholder: View {
    static let height: CGFloat = 220

    let message: String
    let isFailure: Bool

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            if isFailure {
                Image(systemName: "safari.fill")
                    .font(.title2)
            } else {
                ProgressView()
            }
            Text(message)
        }
        .font(Theme.Fonts.bodySm)
        .foregroundStyle(Theme.Colors.onSurfaceMuted)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .padding(.horizontal, Theme.Spacing.xl)
    }
}

private struct InlineCanvasExpandedView: View {
    let file: FileItem
    let session: InlineCanvasSession
    let dismiss: () -> Void
    @Bindable private var canvas: HTMLView

    init(file: FileItem, session: InlineCanvasSession, dismiss: @escaping () -> Void) {
        self.file = file
        self.session = session
        self.dismiss = dismiss
        canvas = session.canvas
    }

    var body: some View {
        NavigationStack {
            WebContentView(page: session.page, mode: .canvas)
                .background(Theme.Colors.conversationSurface)
                .safeAreaInset(edge: .bottom) { CanvasInteractionView(canvas: canvas) }
                .navigationTitle(file.userFacingName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done", action: dismiss)
                            .accessibilityIdentifier(A11yID.ServiceInspector.close)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        FileShareButton(file: file, scope: session.source.scope) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel(A11yLabel.shareFile)
                        .accessibilityIdentifier(A11yID.Files.share(file.id))
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
