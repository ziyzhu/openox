import SwiftUI

struct ArtifactPickerSheet: View {
    let attachedIDs: Set<String>
    let onAttach: ([Artifact]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var artifacts: [Artifact] = []
    @State private var selection: Set<String> = []
    @State private var query = ""
    @State private var loading = true
    @State private var attaching = false
    @State private var attachErrorMessage: String?

    private var matches: [Artifact] {
        artifacts.filter { query.isEmpty || $0.userFacingName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ContentLoadingView(label: "Loading artifacts…")
                } else if artifacts.isEmpty {
                    LibraryEmptyNote(
                        destination: .artifacts,
                        title: "No artifacts yet",
                        detail: "Add a file or photo, or ask Ox to create something in a chat."
                    )
                    .padding(Theme.Spacing.lg)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .accessibilityIdentifier(A11yID.Chat.ArtifactPicker.empty)
                } else if matches.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    list
                }
            }
            .background(Theme.Colors.background)
            .navigationTitle("Artifacts")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier(A11yID.Chat.ArtifactPicker.list)
            .searchable(text: $query, prompt: "Search artifacts")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier(A11yID.Chat.ArtifactPicker.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: attach) {
                        if attaching {
                            CellularAutomatonLoader.small
                        } else {
                            Text("Attach")
                        }
                    }
                        .disabled(selection.isEmpty || attaching)
                        .accessibilityIdentifier(A11yID.Chat.ArtifactPicker.attach)
                }
            }
            .task(id: StorageRoot.currentScope?.root) { await load() }
        }
        .alert("Couldn't download artifact", isPresented: Binding(
            get: { attachErrorMessage != nil },
            set: { if !$0 { attachErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { attachErrorMessage = nil }
        } message: {
            Text(attachErrorMessage ?? "")
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.sm) {
                ForEach(matches) { artifact in
                    let displayed = attaching && selection.contains(artifact.id)
                        ? artifact.updatingAvailability(.downloading)
                        : artifact
                    Button { toggle(artifact) } label: {
                        ArtifactLibraryRow(artifact: displayed, accessory: .selection(selection.contains(artifact.id)))
                    }
                    .buttonStyle(.plain)
                    .disabled(attaching)
                    .accessibilityIdentifier(A11yID.Chat.ArtifactPicker.item(artifact.id))
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.lg)
        }
        .scrollIndicators(.hidden)
    }

    private func toggle(_ artifact: Artifact) {
        if selection.remove(artifact.id) == nil { selection.insert(artifact.id) }
        Haptics.impact(.attachmentChoice)
        Log.ui.info("ArtifactPickerSheet.toggle artifact=\(artifact.id) selected=\(selection.contains(artifact.id))")
    }

    private func attach() {
        Task {
            guard let scope = StorageRoot.currentScope else { return }
            attaching = true
            defer { attaching = false }
            do {
                var picked: [Artifact] = []
                for artifact in artifacts where selection.contains(artifact.id) {
                    picked.append(try await ProfileRepository.shared.materializeArtifact(artifact, in: scope))
                }
                guard StorageRoot.currentScope == scope else { return }
                Log.ui.info("ArtifactPickerSheet.attach count=\(picked.count)")
                onAttach(picked)
                dismiss()
            } catch is CancellationError {
            } catch {
                Log.ui.error("ArtifactPickerSheet.attach download error=\(error.localizedDescription)")
                attachErrorMessage = error.localizedDescription
            }
        }
    }

    private func load() async {
        guard let scope = StorageRoot.currentScope else {
            artifacts = []
            loading = false
            return
        }
        artifacts = await ProfileRepository.shared.artifacts(in: scope)
            .filter { !attachedIDs.contains($0.id) }
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        loading = false
        Log.ui.info("ArtifactPickerSheet.load count=\(artifacts.count) attached=\(attachedIDs.count)")
    }
}
