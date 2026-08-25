import PDFKit
import SwiftUI
import UIKit

struct ArtifactThumbnail: View {
    enum Style: Equatable {
        case composer
        case transcript
        case row
        case library

        var size: CGFloat {
            switch self {
            case .composer: 28
            case .transcript: 96
            case .row: 44
            case .library: 52
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .composer: 7
            case .transcript: 12
            case .row: Theme.Radius.sm
            case .library: Theme.Radius.lg
            }
        }

        var namePadding: CGFloat {
            switch self {
            case .composer: 4
            case .transcript: 6
            case .row, .library: 0
            }
        }

        var showsName: Bool {
            switch self {
            case .transcript: true
            case .composer, .row, .library: false
            }
        }

        var background: DynamicColor {
            switch self {
            case .library: Theme.Colors.surfaceSunken
            case .composer, .transcript, .row: Theme.Colors.background
            }
        }
    }

    let attachment: Artifact
    let style: Style
    var background: DynamicColor? = nil
    var previewSourceID: String? = nil
    @State private var image: UIImage?

    var body: some View {
        Group {
            if attachment.availability == .cloudOnly {
                filePreview(symbol: "icloud.and.arrow.down")
            } else if attachment.availability == .downloading {
                CellularAutomatonLoader(size: 16, tint: Theme.Colors.onSurfaceMuted.dynamic)
            } else if attachment.availability == .unavailable {
                filePreview(symbol: "exclamationmark.icloud")
            } else if attachment.exists {
                switch attachment.kind {
                case .image:
                    visualPreview(fallback: "photo")
                case .pdf:
                    visualPreview(fallback: "doc.richtext")
                case .text:
                    filePreview(symbol: "doc.text")
                case .html:
                    artifactPreview
                case .file:
                    filePreview(symbol: "doc")
                }
            } else {
                filePreview(symbol: "questionmark.document", name: String(localized: "Missing artifact"))
            }
        }
        .frame(width: style.size, height: style.size)
        .background(background ?? style.background, in: shape)
        .clipShape(shape)
        .artifactPreviewTransitionSource(attachment, sourceID: previewSourceID)
        .task(id: attachment.fileURL) {
            image = nil
            guard attachment.availability == .local else { return }
            let kind = attachment.kind
            guard kind == .image || kind == .pdf else { return }
            let size = CGSize(width: style.size * 3, height: style.size * 3)
            let loaded = await Task.detached(priority: .utility) {
                if kind == .image {
                    return UIImage(contentsOfFile: attachment.fileURL.path)
                }
                return PDFDocument(url: attachment.fileURL)?
                    .page(at: 0)?
                    .thumbnail(of: size, for: .cropBox)
            }.value
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
    }

    @ViewBuilder
    private func visualPreview(fallback: String) -> some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            filePreview(symbol: fallback)
        }
    }

    private func filePreview(symbol: String, name: String? = nil) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Theme.Colors.onSurface)
            if style.showsName {
                Text(name ?? attachment.userFacingName)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, style.namePadding)
            }
        }
    }

    private var artifactPreview: some View {
        VStack(spacing: 4) {
            LibraryDestinationIcon(.artifacts)
                .foregroundStyle(Theme.Colors.onSurface)
            if style.showsName {
                Text(attachment.userFacingName)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, style.namePadding)
            }
        }
    }
}
