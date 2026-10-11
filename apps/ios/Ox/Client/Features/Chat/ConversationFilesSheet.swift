import SwiftUI

struct ConversationFilesSheet: View {
    let artifacts: [FileItem]
    let onOpenFile: (FileItem) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: Theme.Spacing.sm) {
                    ForEach(artifacts) { artifact in
                        Button {
                            Log.ui.info("ConversationFilesSheet.navigation select filename=\(artifact.fileName)")
                            onOpenFile(artifact)
                        } label: {
                            FileLibraryRow(artifact: artifact)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(A11yID.Chat.FileItem.item(artifact.id))
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.lg)
            }
            .scrollIndicators(.hidden)
            .background(Theme.Colors.background)
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier(A11yID.Chat.FileItem.list)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier(A11yID.Chat.FileItem.done)
                }
            }
        }
    }
}
