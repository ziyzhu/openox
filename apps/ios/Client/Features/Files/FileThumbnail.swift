import ImageIO
import PDFKit
import SwiftUI
import UIKit

struct FileThumbnail: View {
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
            case .transcript: Theme.Radius.md
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

    let attachment: FileItem
    let style: Style
    let background: DynamicColor?
    let previewSourceID: String?
    let scope: ProfileScope?
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    init(
        attachment: FileItem,
        style: Style,
        background: DynamicColor? = nil,
        previewSourceID: String? = nil,
        scope: ProfileScope? = StorageRoot.currentScope
    ) {
        self.attachment = attachment
        self.style = style
        self.background = background
        self.previewSourceID = previewSourceID
        self.scope = scope
        _image = State(initialValue: Self.cache.object(forKey: Self.cacheKey(attachment, style)))
    }

    private static func cacheKey(_ attachment: FileItem, _ style: Style) -> NSString {
        "\(attachment.fileURL.path)|\(style.size)" as NSString
    }

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
                    libraryPreview
                case .file:
                    filePreview(symbol: "doc")
                }
            } else {
                filePreview(symbol: "questionmark.document", name: String(localized: "Deleted file"))
            }
        }
        .frame(width: style.size, height: style.size)
        .background(background ?? style.background, in: shape)
        .clipShape(shape)
        .filePreviewTransitionSource(attachment, sourceID: previewSourceID)
        .task(id: attachment.fileURL) {
            let key = Self.cacheKey(attachment, style)
            image = Self.cache.object(forKey: key)
            guard image == nil, attachment.availability == .local else { return }
            let kind = attachment.kind
            guard kind == .image || kind == .pdf else { return }
            let size = CGSize(width: style.size * 3, height: style.size * 3)
            let targetPixelSize = max(1, Int((style.size * displayScale).rounded(.up)))
            do {
                let data = try await FilePreviewSource(file: attachment, scope: scope).read()
                let loaded = await Task.detached(priority: .utility) {
                    if kind == .image { return Self.thumbnail(data: data, targetPixelSize: targetPixelSize) }
                    return PDFDocument(data: data)?.page(at: 0)?.thumbnail(of: size, for: .cropBox)
                }.value
                guard !Task.isCancelled, let loaded else { return }
                Self.cache.setObject(loaded, forKey: key, cost: Self.cost(of: loaded))
                withAnimation(reduceMotion ? nil : Theme.Animation.quick) {
                    image = loaded
                }
            } catch is CancellationError {
            } catch {
                Log.ui.error("FileThumbnail.read file=\(attachment.fileName) error=\(error.localizedDescription)")
            }
        }
    }

    nonisolated private static func thumbnail(
        data: Data,
        targetPixelSize: Int
    ) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else { return nil }
        return UIImage(cgImage: thumbnail)
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
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

    private var libraryPreview: some View {
        VStack(spacing: 4) {
            LibraryDestinationIcon(.files)
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
