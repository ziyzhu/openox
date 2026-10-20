import SwiftUI

struct ConversationFilesSheet: View {
    let files: [FileItem]
    let onOpenFile: (FileItem) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: Theme.Spacing.sm) {
                    ForEach(files) { file in
                        Button {
                            Log.ui.info("ConversationFilesSheet.navigation select filename=\(file.fileName)")
                            onOpenFile(file)
                        } label: {
                            FileLibraryRow(file: file)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(A11yID.ConversationControls.FileItem.item(file.id))
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.lg)
            }
            .scrollIndicators(.hidden)
            .background(Theme.Colors.background)
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier(A11yID.ConversationControls.FileItem.list)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier(A11yID.ConversationControls.FileItem.done)
                }
            }
        }
    }
}
