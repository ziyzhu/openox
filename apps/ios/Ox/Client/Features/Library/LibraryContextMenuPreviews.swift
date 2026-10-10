import PDFKit
import SwiftUI
import UIKit

struct ContextMenuPreviewSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(Theme.Spacing.lg)
            .frame(width: 300, alignment: .leading)
            .background(Theme.Colors.surface)
            .themed()
    }
}

struct SkillContextMenuPreview: View {
    let skill: Skill

    var body: some View {
        ContextMenuPreviewSurface {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text(verbatim: "/\(skill.displayName)")
                    .font(Theme.Fonts.title)
                    .foregroundStyle(Theme.Colors.onSurface)

                Text(verbatim: skill.description)
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .lineLimit(4)

                Divider()

                Text(verbatim: skill.instructions)
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .lineLimit(10)

                if !skill.services.isEmpty {
                    Label {
                        if skill.services.count == 1 {
                            Text("1 service")
                        } else {
                            Text("\(skill.services.count) services")
                        }
                    } icon: {
                        Image(systemName: "puzzlepiece.extension")
                    }
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ArtifactContextMenuPreview: View {
    private enum PreviewContent {
        case loading
        case image(UIImage)
        case text(String)
        case unavailable
    }

    let artifact: Artifact
    var scope: ProfileScope? = StorageRoot.currentScope
    @State private var previewContent = PreviewContent.loading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
                .frame(width: 300, height: 240)
                .background(Theme.Colors.surfaceSunken)

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(artifact.userFacingName)
                    .font(Theme.Fonts.title)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .lineLimit(2)
                if let type = artifact.userFacingTypeName {
                    Text(type)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .frame(width: 300)
        .background(Theme.Colors.surface)
        .themed()
        .accessibilityElement(children: .combine)
        .task(id: artifact.fileURL) {
            let loaded = await loadPreview()
            guard !Task.isCancelled else { return }
            previewContent = loaded
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch previewContent {
        case .loading:
            CellularAutomatonLoader.small
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .image(let image):
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text(let text):
            ScrollView {
                Text(verbatim: text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.Colors.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.md)
            }
            .scrollIndicators(.hidden)
        case .unavailable:
            Image(systemName: artifact.kind == .html ? "paintbrush.pointed" : "doc")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadPreview() async -> PreviewContent {
        let artifact = artifact
        guard artifact.kind != .html, artifact.kind != .file else { return .unavailable }
        do {
            let data = try await ArtifactPreviewSource(artifact: artifact, scope: scope).read()
            return await Task.detached(priority: .utility) {
                switch artifact.kind {
                case .image:
                    return UIImage(data: data).map(PreviewContent.image) ?? .unavailable
                case .pdf:
                    let size = CGSize(width: 900, height: 720)
                    guard let page = PDFDocument(data: data)?.page(at: 0) else { return .unavailable }
                    return .image(page.thumbnail(of: size, for: .cropBox))
                case .text:
                    guard let text = String(data: data, encoding: .utf8) else { return .unavailable }
                    return .text(String(text.prefix(4_000)))
                case .html, .file:
                    return .unavailable
                }
            }.value
        } catch is CancellationError {
            return .unavailable
        } catch {
            Log.ui.error("ArtifactContextMenuPreview.read file=\(artifact.fileName) error=\(error.localizedDescription)")
            return .unavailable
        }
    }
}
