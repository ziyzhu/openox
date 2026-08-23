import SwiftUI

struct ChatArtifactsSheet: View {
    let artifacts: [Artifact]
    let onOpenArtifact: (Artifact) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: Theme.Spacing.sm) {
                    ForEach(artifacts) { artifact in
                        Button {
                            Log.ui.info("ChatArtifactsSheet.navigation select filename=\(artifact.fileName)")
                            onOpenArtifact(artifact)
                        } label: {
                            ArtifactLibraryRow(artifact: artifact)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(A11yID.Chat.Artifact.item(artifact.id))
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.lg)
            }
            .scrollIndicators(.hidden)
            .background(Theme.Colors.background)
            .navigationTitle("Artifacts")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier(A11yID.Chat.Artifact.list)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier(A11yID.Chat.Artifact.done)
                }
            }
        }
    }
}
