import SwiftUI
import UIKit

struct ImageWidgetView: View {
    let image: ImageWidget
    var scope: ProfileScope? = StorageRoot.currentScope

    private enum LoadState {
        case loading
        case ready(UIImage)
        case failed
    }

    private struct Preview: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    private struct LoadRequest: Equatable {
        let image: ImageWidget
        let retry: Int
    }

    @State private var state = LoadState.loading
    @State private var preview: Preview?
    @State private var retry = 0

    var body: some View {
        surface
            .frame(maxWidth: .infinity)
            .background(Theme.Colors.background)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .chatCardOutline(cornerRadius: Theme.Radius.md)
            .task(id: LoadRequest(image: image, retry: retry)) { await load() }
            .fullScreenCover(item: $preview) { preview in
                ArtifactScreen(onDismiss: { self.preview = nil }, dismissIdentifier: A11yID.Chat.Message.imageClose) { _ in
                    ZoomableImageView(image: preview.image)
                }
            }
    }

    @ViewBuilder
    private var surface: some View {
        switch state {
        case .loading:
            CellularAutomatonLoader(size: 16, tint: Theme.Colors.onSurfaceMuted.dynamic)
                .frame(height: 160)
                .accessibilityLabel("Loading image")
        case let .ready(loaded):
            Button { preview = Preview(image: loaded) } label: {
                Image(uiImage: loaded)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 320)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open image")
            .accessibilityHint("Pinch or double-tap to zoom")
            .accessibilityIdentifier(A11yID.Chat.Message.imageOpen)
        case .failed:
            Button { retry += 1 } label: {
                VStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "photo")
                        .font(Theme.Icons.lg)
                    Text("Couldn't load image")
                        .font(Theme.Fonts.bodySm)
                    Text("Retry")
                        .font(Theme.Fonts.bodySm)
                }
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .frame(maxWidth: .infinity)
                .frame(height: 160)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(A11yID.Chat.Message.imageRetry)
        }
    }

    private func load() async {
        state = .loading
        do {
            let data: Data
            switch image.source {
            case let .artifact(artifact):
                data = try await ArtifactPreviewSource(artifact: artifact, scope: scope).read()
            case let .remote(value):
                let request = try WebFetchRequest(url: value)
                guard request.url.scheme == "https" else { throw ImagePreparationError.invalid }
                let response = try await WebFetchClient.shared.fetch(request)
                guard response.ok, response.url.scheme == "https" else { throw ImagePreparationError.invalid }
                data = response.data
            }
            let loaded = try await Task.detached(priority: .userInitiated) {
                let prepared = try ImagePreparer.prepare(data)
                guard let image = UIImage(data: prepared.data) else { throw ImagePreparationError.invalid }
                return image
            }.value
            try Task.checkCancellation()
            state = .ready(loaded)
            Log.ui.info("ImageWidgetView.load ready source=\(image.source.artifact == nil ? "remote" : "artifact") bytes=\(data.count)")
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed
            Log.ui.error("ImageWidgetView.load failed source=\(image.source.artifact == nil ? "remote" : "artifact") error=\(LogPrivacy.text(error.localizedDescription))")
        }
    }
}
