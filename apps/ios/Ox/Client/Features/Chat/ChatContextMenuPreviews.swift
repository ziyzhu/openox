import SwiftUI

struct ConversationContextMenuPreview: View {
    let meta: ChatMeta

    var body: some View {
        ContextMenuPreviewSurface {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text(meta.displayTitle)
                    .font(Theme.Fonts.title)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .lineLimit(2)

                if let preview = meta.preview?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !preview.isEmpty,
                   preview != meta.displayTitle {
                    Text(preview)
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.onSurface)
                        .lineLimit(8)
                }

                HStack(spacing: Theme.Spacing.sm) {
                    Text(meta.activityDate.formatted(date: .abbreviated, time: .shortened))
                    if !meta.attachedServiceDomains.isEmpty {
                        Text("·")
                        Label {
                            Text("\(meta.attachedServiceDomains.count)")
                        } icon: {
                            Image(systemName: "puzzlepiece.extension")
                        }
                    }
                }
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct MessageContextMenuPreview: View {
    let title: String?
    let text: String
    let attachments: [Artifact]

    var body: some View {
        ContextMenuPreviewSurface {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if let title {
                    Text(title)
                        .font(Theme.Fonts.title)
                        .foregroundStyle(Theme.Colors.onSurface)
                        .lineLimit(2)
                }

                if !text.isEmpty {
                    Text(verbatim: text)
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.onSurface)
                        .lineLimit(12)
                }

                ForEach(attachments.prefix(2)) { artifact in
                    HStack(spacing: Theme.Spacing.sm) {
                        ArtifactThumbnail(attachment: artifact, style: .row)
                        Text(artifact.userFacingName)
                            .font(Theme.Fonts.bodySm)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                            .lineLimit(2)
                    }
                }

                if attachments.count > 2 {
                    Text("\(attachments.count - 2) more attachments")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
