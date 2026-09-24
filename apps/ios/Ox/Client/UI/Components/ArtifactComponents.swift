import SwiftUI

struct ArtifactLibraryRow: View {
    enum Accessory {
        case none
        case disclosure
        case selection(Bool)
    }

    let artifact: Artifact
    var accessory: Accessory = .disclosure
    var showsContainer = true
    var horizontalPadding = Theme.Spacing.md
    var verticalPadding = Theme.Spacing.md
    var previewSourceID: String? = nil

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            ArtifactThumbnail(
                attachment: artifact,
                style: .library,
                background: showsContainer ? Theme.Colors.surfaceSunken : Theme.Colors.surface
            )
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(artifact.userFacingName)
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let metadata {
                    Text(metadata)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            switch accessory {
            case .none:
                EmptyView()
            case .disclosure:
                Image(systemName: "chevron.right")
                    .font(Theme.Icons.xs)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
            case .selection(let selected):
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(Theme.Icons.md)
                    .foregroundStyle(selected ? Theme.Colors.primary : Theme.Colors.onSurfaceMuted)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if showsContainer {
                SettingsSurfaceShape()
                    .fill(Theme.Colors.surface)
            }
        }
        .contentShape(Rectangle())
        .artifactPreviewTransitionSource(artifact, sourceID: previewSourceID)
    }

    private var metadata: String? {
        let values = [
            artifact.userFacingTypeName,
            artifact.availabilityDescription,
            artifact.modifiedAt?.formatted(date: .abbreviated, time: .omitted),
        ].compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }
}

struct ArtifactContextMenu: View {
    let artifact: Artifact
    let canMutate: Bool
    let onRename: () -> Void
    let onDelete: () -> Void
    var isSaved: Bool? = nil
    var onToggleSaved: (() -> Void)? = nil

    var body: some View {
        if artifact.availability == .local {
            if let isSaved, let onToggleSaved {
                Button(action: onToggleSaved) {
                    Label(isSaved ? "Unsave" : "Save", systemImage: isSaved ? "bookmark.fill" : "bookmark")
                }
                .accessibilityIdentifier(A11yID.Artifacts.save(artifact.id))
            }

            ShareLink(item: artifact.fileURL) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .accessibilityLabel(A11yLabel.shareArtifact)
            .accessibilityIdentifier(A11yID.Artifacts.share(artifact.id))

            if canMutate {
                Button(action: onRename) {
                    Label("Rename", systemImage: "pencil")
                }
                .accessibilityIdentifier(A11yID.Artifacts.rename(artifact.id))

                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
                .accessibilityIdentifier(A11yID.Artifacts.delete(artifact.id))
            }
        }
    }
}

struct ArtifactPreviewPresentation: View {
    let artifact: Artifact

    var body: some View {
        ArtifactZoomPreviewScreen(
            artifact: artifact,
            chrome: .navigation
        )
    }
}

struct ArtifactZoomPreviewPresentation: View {
    let preview: ArtifactZoomPreview
    let namespace: Namespace.ID
    let onDismiss: () -> Void

    var body: some View {
        ArtifactZoomPreviewScreen(
            artifact: preview.artifact,
            chrome: .immersive(onDismiss: onDismiss)
        )
            .navigationTransition(.zoom(sourceID: preview.sourceID, in: namespace))
    }
}

private struct ArtifactZoomPreviewCover: ViewModifier {
    let presentation: ZoomPresentation<ArtifactZoomPreview>
    let namespace: Namespace.ID
    let onDismiss: (Artifact) -> Void

    func body(content: Content) -> some View {
        content
            .scrollDisabled(presentation.isDismissing)
            .environment(\.artifactPreviewNamespace, namespace)
            .fullScreenCover(item: presentation.binding, onDismiss: finishDismissal) { presented in
                ArtifactZoomPreviewPresentation(preview: presented, namespace: namespace) {
                    presentation.dismiss()
                }
            }
    }

    private func finishDismissal() {
        presentation.finishDismissal { onDismiss($0.artifact) }
    }
}

enum ArtifactMutation: Equatable {
    case renaming(Artifact, draft: String)
    case renameFailed(String)
    case deleting(Artifact)
    case deleteFailed(String)

    static func rename(_ artifact: Artifact) -> ArtifactMutation {
        .renaming(artifact, draft: artifact.userFacingName)
    }
}

private struct ArtifactMutationAlerts: ViewModifier {
    @Binding var mutation: ArtifactMutation?
    let onRename: (Artifact, String) -> Void
    let onDelete: (Artifact) -> Void

    func body(content: Content) -> some View {
        content
            .alert("Rename an artifact", isPresented: presented { if case .renaming = $0 { true } else { false } }) {
                TextField("Name", text: renameDraft)
                Button("Cancel", role: .cancel) { mutation = nil }
                Button("Rename") {
                    guard case .renaming(let artifact, let draft) = mutation else { return }
                    mutation = nil
                    onRename(artifact, artifact.fileName(forUserFacingName: draft))
                }
                .disabled(!canSubmitRename)
                .accessibilityIdentifier(A11yID.Artifacts.renameSubmit)
            }
            .alert("Rename an artifact", isPresented: presented { if case .renameFailed = $0 { true } else { false } }) {
                Button("OK", role: .cancel) { mutation = nil }
            } message: {
                Text(failureMessage)
            }
            .alert("Delete this artifact?", isPresented: presented { if case .deleting = $0 { true } else { false } }) {
                Button("Cancel", role: .cancel) { mutation = nil }
                Button("Delete", role: .destructive) {
                    guard case .deleting(let artifact) = mutation else { return }
                    mutation = nil
                    onDelete(artifact)
                }
                .accessibilityIdentifier(A11yID.Artifacts.deleteConfirm)
            } message: {
                Text("This removes the artifact from this Profile. Existing chat references will show a deleted placeholder. This can't be undone.")
            }
            .alert("Couldn't delete artifact", isPresented: presented { if case .deleteFailed = $0 { true } else { false } }) {
                Button("OK", role: .cancel) { mutation = nil }
            } message: {
                Text(failureMessage)
            }
    }

    private func presented(_ matches: @escaping (ArtifactMutation) -> Bool) -> Binding<Bool> {
        Binding(
            get: { mutation.map(matches) ?? false },
            set: { if !$0, mutation.map(matches) == true { mutation = nil } }
        )
    }

    private var renameDraft: Binding<String> {
        Binding(
            get: {
                guard case .renaming(_, let draft) = mutation else { return "" }
                return draft
            },
            set: {
                guard case .renaming(let artifact, _) = mutation else { return }
                mutation = .renaming(artifact, draft: $0)
            }
        )
    }

    private var canSubmitRename: Bool {
        guard case .renaming(let artifact, let draft) = mutation else { return false }
        return !draft.isEmpty && draft != artifact.userFacingName
    }

    private var failureMessage: String {
        switch mutation {
        case .renameFailed(let message), .deleteFailed(let message): message
        case .renaming, .deleting, nil: ""
        }
    }
}

extension View {
    func artifactZoomPreviewCover(
        presentation: ZoomPresentation<ArtifactZoomPreview>,
        namespace: Namespace.ID,
        onDismiss: @escaping (Artifact) -> Void
    ) -> some View {
        modifier(ArtifactZoomPreviewCover(
            presentation: presentation,
            namespace: namespace,
            onDismiss: onDismiss
        ))
    }

    func artifactMutationAlerts(
        _ mutation: Binding<ArtifactMutation?>,
        onRename: @escaping (Artifact, String) -> Void,
        onDelete: @escaping (Artifact) -> Void
    ) -> some View {
        modifier(ArtifactMutationAlerts(mutation: mutation, onRename: onRename, onDelete: onDelete))
    }
}
