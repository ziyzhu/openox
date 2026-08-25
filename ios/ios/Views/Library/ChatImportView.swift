import SwiftUI

struct ChatImportView: View {
    let proposal: ChatImportProposal
    let coordinator: ChatImportCoordinator
    let chats: ChatManager

    private var artifactBytes: Int {
        proposal.header.files.reduce(0) { total, file in
            file.path.hasPrefix("artifacts/") ? total + file.bytes : total
        }
    }

    private var artifactSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(artifactBytes), countStyle: .file)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Theme.Colors.onSurface)
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(verbatim: proposal.header.title)
                            .font(Theme.Fonts.title)
                            .foregroundStyle(Theme.Colors.onSurface)
                        Text("\(proposal.header.turnCount) messages")
                            .font(Theme.Fonts.bodyMd)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(A11yID.ChatImport.preview)

                Label(
                    "\(proposal.header.artifactCount) artifacts · \(artifactSize)",
                    systemImage: "doc.on.doc"
                )
                .font(Theme.Fonts.bodySm)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)

                if proposal.header.hasCompactedContext {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Label("Includes compacted context", systemImage: "text.badge.checkmark")
                            .font(Theme.Fonts.labelMd)
                            .foregroundStyle(Theme.Colors.onSurface)
                        Text("Compacted context can contain details that aren't visible in the chat.")
                            .font(Theme.Fonts.bodySm)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    }
                }

                if !proposal.header.serviceDomains.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Referenced plugins")
                            .font(Theme.Fonts.labelMd)
                            .foregroundStyle(Theme.Colors.onSurface)
                        Text(verbatim: proposal.header.serviceDomains.joined(separator: ", "))
                            .font(Theme.Fonts.bodySm)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                        Text("Plugins won't be attached automatically.")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    }
                }

                Spacer(minLength: 0)

                Button("Add Chat") { coordinator.install(using: chats) }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(coordinator.isSaving)
                    .accessibilityIdentifier(A11yID.ChatImport.add)
            }
            .padding(Theme.Spacing.lg)
            .background(Theme.Colors.background)
            .navigationTitle("Add Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { coordinator.dismissProposal() }
                        .disabled(coordinator.isSaving)
                        .accessibilityIdentifier(A11yID.ChatImport.cancel)
                }
            }
            .overlay {
                if coordinator.isSaving {
                    Rectangle()
                        .fill(Theme.Colors.background.opacity(0.65))
                        .ignoresSafeArea()
                    CellularAutomatonLoader(tint: Theme.Colors.onSurface.dynamic)
                }
            }
        }
    }
}
