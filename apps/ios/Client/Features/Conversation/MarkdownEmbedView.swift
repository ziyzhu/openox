import SwiftUI

struct MarkdownEmbedView: View {
    let alt: String
    let path: String
    @Environment(\.conversationFileResolver) private var resolver
    @Environment(\.conversationLinkHandler) private var openLink
    @State private var resolution: Resolution?

    private enum Resolution: Equatable {
        case found(FileItem)
        case removed
    }

    private struct ResolveKey: Equatable {
        let path: String
        let revision: Int?
    }

    var body: some View {
        if path.hasPrefix("https:") {
            ImageWidgetView(image: ImageWidget(source: .remote(path)))
        } else {
            fileContent
        }
    }

    private var fileContent: some View {
        content
            .task(id: ResolveKey(path: path, revision: resolver?.revision)) {
                let file = await resolver?.resolve(path)
                guard !Task.isCancelled else { return }
                resolution = file.flatMap { $0.exists ? .found($0) : nil } ?? .removed
                Log.ui.info("MarkdownEmbed.resolve path=\(path) found=\(file?.exists == true)")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch resolution {
        case nil:
            Color.clear.frame(height: 52)
        case .found(let file) where file.kind == .html:
            InlineCanvasCard(artifact: file, rowID: StableID.uuid("markdown.embed.\(path)"))
        case .found(let file) where file.kind == .image || file.isSVG:
            ImageWidgetView(image: ImageWidget(source: .artifact(file)))
        case .found(let file) where file.isVideo:
            VideoWidgetView(video: VideoWidget(source: .artifact(file)))
        case .found(let file):
            Button { open() } label: {
                fileLine(file, removed: false)
            }
            .buttonStyle(.plain)
            .accessibilityHint(String(format: L10n.string("Opens %@"), file.userFacingName))
            .accessibilityIdentifier(A11yID.ConversationControls.Message.artifact(file.id))
        case .removed:
            fileLine(FileItem(fileName: removedName, directory: URL(fileURLWithPath: "/")), removed: true)
                .accessibilityLabel(String(format: L10n.string("%@, deleted file"), removedName))
                .accessibilityIdentifier(A11yID.ConversationControls.Message.artifact(removedName))
        }
    }

    private func fileLine(_ file: FileItem, removed: Bool) -> some View {
        Label {
            Text(file.userFacingName)
                .underline(!removed, pattern: .dot)
                .strikethrough(removed)
        } icon: {
            Image(systemName: FileCardFormat(file: file).symbol)
        }
        .font(Theme.Fonts.bodyMd)
        .foregroundStyle(removed ? Theme.Colors.conversationSecondary : Theme.Colors.onSurface)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(minHeight: Theme.Size.minimumTouchTarget)
        .contentShape(Rectangle())
    }

    private var removedName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private func open() {
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: encoded) else { return }
        openLink?(url)
    }
}
