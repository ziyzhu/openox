import SwiftUI

struct FileLibraryRow: View {
    enum Accessory {
        case none
        case disclosure
        case selection(Bool)
    }

    let artifact: FileItem
    var accessory: Accessory = .disclosure
    var showsContainer = true
    var horizontalPadding = Theme.Spacing.md
    var verticalPadding = Theme.Spacing.md
    var previewSourceID: String? = nil
    var scope: ProfileScope? = StorageRoot.currentScope

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            FileThumbnail(
                attachment: artifact,
                style: .library,
                background: showsContainer ? Theme.Colors.surfaceSunken : Theme.Colors.surface,
                scope: scope
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

struct FileContextMenu: View {
    let artifact: FileItem
    let canMutate: Bool
    let onRename: () -> Void
    let onDelete: () -> Void
    var scope: ProfileScope? = StorageRoot.currentScope

    var body: some View {
        if artifact.availability == .local {
            FileShareButton(artifact: artifact, scope: scope) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .accessibilityLabel(A11yLabel.shareFile)
            .accessibilityIdentifier(A11yID.Files.share(artifact.id))

            if canMutate {
                Button(action: onRename) {
                    Label("Rename", systemImage: "pencil")
                }
                .accessibilityIdentifier(A11yID.Files.rename(artifact.id))

                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
                .accessibilityIdentifier(A11yID.Files.delete(artifact.id))
            }
        }
    }
}

struct FilePreviewPresentation: View {
    let artifact: FileItem
    var scope: ProfileScope? = StorageRoot.currentScope

    var body: some View {
        FileZoomPreviewScreen(
            artifact: artifact,
            chrome: .navigation,
            scope: scope
        )
    }
}

struct FileZoomPreviewPresentation: View {
    let preview: FileZoomPreview
    let namespace: Namespace.ID
    let onDismiss: () -> Void

    var body: some View {
        FileZoomPreviewScreen(
            artifact: preview.artifact,
            chrome: .immersive(onDismiss: onDismiss),
            scope: preview.scope
        )
            .navigationTransition(.zoom(sourceID: preview.sourceID, in: namespace))
    }
}

private struct FileZoomPreviewCover: ViewModifier {
    let presentation: ZoomPresentation<FileZoomPreview>
    let namespace: Namespace.ID
    let onDismiss: (FileItem) -> Void

    func body(content: Content) -> some View {
        content
            .scrollDisabled(presentation.isDismissing)
            .environment(\.artifactPreviewNamespace, namespace)
            .fullScreenCover(item: presentation.binding, onDismiss: finishDismissal) { presented in
                FileZoomPreviewPresentation(preview: presented, namespace: namespace) {
                    presentation.dismiss()
                }
            }
    }

    private func finishDismissal() {
        presentation.finishDismissal { onDismiss($0.artifact) }
    }
}

enum FileMutation: Equatable {
    case renaming(FileItem, draft: String)
    case renameFailed(String)
    case deleting(FileItem)
    case deleteFailed(String)

    static func rename(_ artifact: FileItem) -> FileMutation {
        .renaming(artifact, draft: artifact.userFacingName)
    }
}

private struct FileMutationAlerts: ViewModifier {
    @Binding var mutation: FileMutation?
    let onRename: (FileItem, String) -> Void
    let onDelete: (FileItem) -> Void

    func body(content: Content) -> some View {
        content
            .alert("Rename file", isPresented: presented { if case .renaming = $0 { true } else { false } }) {
                TextField("Name", text: renameDraft)
                Button("Cancel", role: .cancel) { mutation = nil }
                Button("Rename") {
                    guard case .renaming(let artifact, let draft) = mutation else { return }
                    mutation = nil
                    onRename(artifact, artifact.fileName(forUserFacingName: draft))
                }
                .disabled(!canSubmitRename)
                .accessibilityIdentifier(A11yID.Files.renameSubmit)
            }
            .alert("Rename file", isPresented: presented { if case .renameFailed = $0 { true } else { false } }) {
                Button("OK", role: .cancel) { mutation = nil }
            } message: {
                Text(failureMessage)
            }
            .alert("Delete this file?", isPresented: presented { if case .deleting = $0 { true } else { false } }) {
                Button("Cancel", role: .cancel) { mutation = nil }
                Button("Delete", role: .destructive) {
                    guard case .deleting(let artifact) = mutation else { return }
                    mutation = nil
                    onDelete(artifact)
                }
                .accessibilityIdentifier(A11yID.Files.deleteConfirm)
            } message: {
                Text("This deletes the file. Existing chat references will show it as deleted.")
            }
            .alert("Couldn't delete file", isPresented: presented { if case .deleteFailed = $0 { true } else { false } }) {
                Button("OK", role: .cancel) { mutation = nil }
            } message: {
                Text(failureMessage)
            }
    }

    private func presented(_ matches: @escaping (FileMutation) -> Bool) -> Binding<Bool> {
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
        presentation: ZoomPresentation<FileZoomPreview>,
        namespace: Namespace.ID,
        onDismiss: @escaping (FileItem) -> Void
    ) -> some View {
        modifier(FileZoomPreviewCover(
            presentation: presentation,
            namespace: namespace,
            onDismiss: onDismiss
        ))
    }

    func artifactMutationAlerts(
        _ mutation: Binding<FileMutation?>,
        onRename: @escaping (FileItem, String) -> Void,
        onDelete: @escaping (FileItem) -> Void
    ) -> some View {
        modifier(FileMutationAlerts(mutation: mutation, onRename: onRename, onDelete: onDelete))
    }
}
