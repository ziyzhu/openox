import AVFoundation
import PDFKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct FileCardView: View {
    enum Footer {
        case details
        case name
    }

    let file: FileItem
    var footer = Footer.details
    var title: String?
    var description: String?
    var badge: String?
    var scope: ProfileScope? = StorageRoot.currentScope

    @State private var preview = FileCardContent.loading
    @State private var detail: String?

    private var format: FileCardFormat { FileCardFormat(file: file) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if format.hasPreview {
                previewSurface
                    .frame(height: 160, alignment: .top)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .accessibilityHidden(true)
            }
            Group {
                switch footer {
                case .details: details
                case .name: name
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 240, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Colors.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .accessibilityElement(children: .combine)
        .task(id: file) {
            preview = .loading
            detail = nil
            guard file.availability == .local, file.exists else {
                preview = .fallback
                return
            }
            do {
                let loaded = try await FileCardLoader.load(file: file, scope: scope, format: format)
                try Task.checkCancellation()
                preview = loaded.content
                detail = loaded.detail
                Log.ui.info("FileCardView.load ready file=\(file.fileName) format=\(String(describing: format))")
            } catch is CancellationError {
            } catch {
                preview = .fallback
                Log.ui.error("FileCardView.load file=\(file.fileName) error=\(error.localizedDescription)")
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if let badge {
                Text(badge)
                    .font(Theme.Fonts.captionMd)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
            }
            Label(title ?? file.userFacingName, systemImage: format.symbol)
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurface)
                .lineLimit(2)
            if title != nil, title != file.userFacingName {
                Text(file.userFacingName)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .lineLimit(1)
            }
            Text(metadata)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .lineLimit(2)
            if let description {
                Text(description)
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .lineLimit(3)
            }
        }
        .padding(Theme.Spacing.md)
    }

    private var name: some View {
        Text(file.userFacingName)
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.Colors.onSurfaceMuted)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
    }

    private var metadata: String {
        let availability = file.availabilityDescription ?? (file.exists ? nil : String(localized: "Deleted file"))
        let size = file.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        return [file.userFacingTypeName ?? file.fileURL.pathExtension.uppercased(), availability, detail, size]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private var previewSurface: some View {
        switch preview {
        case .loading:
            CellularAutomatonLoader.small
        case .image(let image):
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        case .text(let source):
            Text(verbatim: source)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(Theme.Spacing.md)
        case .markdown(let source):
            MarkdownText(source, accessibilityIdentifier: "file.card.preview.\(file.id)")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(Theme.Spacing.md)
                .allowsHitTesting(false)
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.sm, verticalSpacing: Theme.Spacing.sm) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(verbatim: cell)
                                .font(index == 0 ? Theme.Fonts.captionMd : Theme.Fonts.caption)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if index == 0 { Divider().gridCellColumns(rows.first?.count ?? 1) }
                }
            }
            .padding(Theme.Spacing.md)
        case .media(let image):
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                }
                Image(systemName: file.isVideo ? "play.circle.fill" : "waveform")
                    .font(Theme.Icons.xl)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .padding(Theme.Spacing.sm)
                    .background(Theme.Colors.background, in: Circle())
            }
        case .fallback:
            Image(systemName: file.availability == .local ? format.symbol : "icloud.and.arrow.down")
                .font(Theme.Icons.xl)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
        }
    }
}

private enum FileCardContent {
    case loading
    case image(UIImage)
    case text(String)
    case markdown(String)
    case table([[String]])
    case media(UIImage?)
    case fallback
}

enum FileCardFormat {
    case image, svg, pdf, markdown, text, table, spreadsheet, html, audio, video, archive, file

    init(file: FileItem) {
        let type = UTType(file.typeIdentifier) ?? .data
        let suffix = file.fileURL.pathExtension.lowercased()
        if file.isMarkdown { self = .markdown }
        else if file.isSVG { self = .svg }
        else if file.isVideo { self = .video }
        else if type.conforms(to: .audio) { self = .audio }
        else if ["csv", "tsv"].contains(suffix) { self = .table }
        else if type.conforms(to: .spreadsheet) || ["xlsx", "xls", "ods", "numbers"].contains(suffix) { self = .spreadsheet }
        else if type.conforms(to: .archive) { self = .archive }
        else {
            self = switch file.kind {
            case .image: .image
            case .pdf: .pdf
            case .text: .text
            case .html: .html
            case .file: .file
            }
        }
    }

    var hasPreview: Bool { self != .archive && self != .file }

    var symbol: String {
        switch self {
        case .image, .svg: "photo"
        case .pdf: "doc.richtext"
        case .markdown, .text: "doc.text"
        case .table, .spreadsheet: "tablecells"
        case .html: "globe"
        case .audio: "waveform"
        case .video: "video"
        case .archive: "doc.zipper"
        case .file: "doc"
        }
    }
}

private enum FileCardLoader {
    struct Result {
        let content: FileCardContent
        var detail: String? = nil
    }

    static func load(file: FileItem, scope: ProfileScope?, format: FileCardFormat) async throws -> Result {
        guard format.hasPreview else { return Result(content: .fallback) }
        let snapshot = try await FilePreviewSource(file: file, scope: scope).snapshot()
        switch format {
        case .text, .markdown, .table:
            let source = try await text(at: snapshot.url)
            switch format {
            case .markdown: return Result(content: .markdown(source))
            case .table: return Result(content: .table(rows(source, separator: file.fileURL.pathExtension.lowercased() == "tsv" ? "\t" : ",")))
            default: return Result(content: .text(source))
            }
        case .audio, .video:
            let asset = AVURLAsset(url: snapshot.url)
            let duration = try await asset.load(.duration).seconds
            let detail = duration.isFinite && duration >= 0 ? Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)) : nil
            var image: UIImage?
            if format == .video {
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 720, height: 480)
                image = try? await UIImage(cgImage: generator.image(at: .zero).image)
            }
            return Result(content: .media(image), detail: detail)
        case .html:
            return Result(content: .image(try await WebSnapshot.image(html: html(at: snapshot.url), size: CGSize(width: 480, height: 320))))
        case .svg:
            return Result(content: .image(try await WebSnapshot.image(svg: data(at: snapshot.url), width: 480)))
        default:
            let request = QLThumbnailGenerator.Request(fileAt: snapshot.url, size: CGSize(width: 480, height: 320), scale: 2, representationTypes: .thumbnail)
            let image = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
            let detail = format == .pdf ? await pageCount(at: snapshot.url) : nil
            return Result(content: .image(image), detail: detail)
        }
    }

    @concurrent private static func text(at url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 8_192) ?? Data()
        return String(String(decoding: bytes, as: UTF8.self).prefix(2_000))
    }

    @concurrent private static func pageCount(at url: URL) async -> String? {
        guard let count = PDFDocument(url: url)?.pageCount else { return nil }
        return String(localized: "\(count) pages")
    }

    private static func rows(_ source: String, separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var quoted = false
        var characters = source.makeIterator()
        var next = characters.next()
        while let character = next, rows.count < 5 {
            next = characters.next()
            if character == "\"" {
                if quoted, next == "\"" { cell.append("\""); next = characters.next() }
                else { quoted.toggle() }
            } else if !quoted, character == separator {
                row.append(cell); cell = ""
            } else if !quoted, character == "\n" {
                row.append(cell); rows.append(Array(row.prefix(3))); row = []; cell = ""
            } else if character != "\r" { cell.append(character) }
        }
        if rows.count < 5, !cell.isEmpty || !row.isEmpty { row.append(cell); rows.append(Array(row.prefix(3))) }
        let columns = rows.map(\.count).max() ?? 1
        return rows.map { $0 + Array(repeating: "", count: columns - $0.count) }
    }
}

private extension FileCardLoader {
    @concurrent static func html(at url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 512 * 1_024) ?? Data()
        return String(decoding: bytes, as: UTF8.self)
    }

    @concurrent static func data(at url: URL) async throws -> Data {
        try Data(contentsOf: url, options: .mappedIfSafe)
    }
}
