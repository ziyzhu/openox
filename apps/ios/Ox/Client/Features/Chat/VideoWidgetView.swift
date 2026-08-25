import AVFoundation
import AVKit
import Combine
import SwiftUI
import UIKit

struct VideoWidgetView: View {
    let video: VideoWidget

    @Environment(ServiceManager.self) private var serviceManager
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var thumbnail: UIImage?
    @State private var asset: AVURLAsset?
    @State private var failed = false
    @State private var statusObserver: AnyCancellable?

    var body: some View {
        playerSurface
            .onDisappear { teardown() }
    }

    @ViewBuilder
    private var playerSurface: some View {
        ZStack {
            Rectangle().fill(Theme.Colors.background)
            if failed {
                VStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(Theme.Icons.lg)
                    Text("Couldn't load video")
                        .font(Theme.Fonts.bodySm)
                }
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
            } else if isPlaying, let player {
                InlineVideoPlayer(player: player)
            } else {
                Button(action: start) {
                    Group {
                        if let thumbnail {
                            Color.clear.overlay {
                                Image(uiImage: thumbnail)
                                    .resizable()
                                    .scaledToFill()
                            }
                            .clipped()
                        } else {
                            Rectangle().fill(Theme.Colors.background)
                        }
                    }
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(Theme.Icons.xl)
                            .foregroundStyle(.white)
                            .padding(20)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                }
                .buttonStyle(.plain)
                .disabled(asset == nil)
                .accessibilityLabel("Play video")
                .accessibilityIdentifier(A11yID.Chat.Message.videoPlay)
            }
        }
        .aspectRatio(4 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .task { await load() }
    }

    private func teardown() {
        statusObserver?.cancel()
        statusObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
    }

    private func start() {
        guard let asset else { return }
        if player == nil {
            let item = AVPlayerItem(asset: asset)
            statusObserver = item.publisher(for: \.status)
                .receive(on: DispatchQueue.main)
                .sink { status in
                    guard status == .failed else { return }
                    failed = true
                    isPlaying = false
                    Log.ui.error("VideoWidgetView.playback failed=\(item.error?.localizedDescription ?? "unknown")")
                }
            player = AVPlayer(playerItem: item)
        }
        player?.play()
        isPlaying = true
        Log.ui.info("VideoWidgetView.play")
    }

    private func load() async {
        guard asset == nil else { return }
        guard let loaded = await VideoWidgetAsset.asset(for: video.source, serviceManager: serviceManager) else {
            failed = true
            Log.ui.error("VideoWidgetView.load failed")
            return
        }
        asset = loaded
        let generator = AVAssetImageGenerator(asset: loaded)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 450)
        if let image = try? await generator.image(at: .zero).image {
            thumbnail = UIImage(cgImage: image)
        }
        Log.ui.info("VideoWidgetView.load ready")
    }
}

private enum VideoWidgetAsset {
    static func asset(for source: VideoWidget.Source, serviceManager: ServiceManager) async -> AVURLAsset? {
        switch source {
        case let .artifact(artifact):
            guard artifact.exists, artifact.isVideo else { return nil }
            return AVURLAsset(url: artifact.fileURL)
        case let .remote(value):
            guard let url = URL(string: value) else { return nil }
            let cookies = await serviceManager.cookies(for: url)
            let options = cookies.isEmpty ? [:] : [AVURLAssetHTTPCookiesKey: cookies]
            return AVURLAsset(url: url, options: options)
        }
    }
}

private struct InlineVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.videoGravity = .resizeAspect
        controller.allowsVideoFrameAnalysis = false
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiViewController: AVPlayerViewController,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: width * 3 / 4)
    }
}
