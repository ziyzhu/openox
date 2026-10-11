import SwiftUI

struct FilePickerSheet: View {
    let attachedIDs: Set<String>
    let onAttach: ([FileItem]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var artifacts: [FileItem] = []
    @State private var selection: Set<String> = []
    @State private var query = ""
    @State private var loading = true
    @State private var attaching = false
    @State private var attachErrorMessage: String?
    @State private var loadErrorMessage: String?
    @State private var loadedScope: ProfileScope?

    private var matches: [FileItem] {
        artifacts.filter { query.isEmpty || $0.userFacingName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ContentLoadingView(label: "Loading files…")
                } else if let loadErrorMessage {
                    ContentUnavailableView("File unavailable", systemImage: "exclamationmark.triangle", description: Text(loadErrorMessage))
                } else if artifacts.isEmpty {
                    LibraryEmptyNote(
                        destination: .artifacts,
                        title: "No files yet",
                        detail: "Add a file or photo, or ask Ox to create something in a chat."
                    )
                    .padding(Theme.Spacing.lg)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .accessibilityIdentifier(A11yID.Chat.FilePicker.empty)
                } else if matches.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    list
                }
            }
            .background(Theme.Colors.background)
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier(A11yID.Chat.FilePicker.list)
            .oxSearchable(text: $query, prompt: Text("Search files"), accessibilityIdentifier: A11yID.Chat.FilePicker.search)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier(A11yID.Chat.FilePicker.cancel)
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
                        .accessibilityIdentifier(A11yID.Chat.FilePicker.attach)
                }
            }
            .task(id: StorageRoot.currentScope?.root) { await load() }
        }
        .alert("Couldn't download file", isPresented: Binding(
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
                        FileLibraryRow(artifact: displayed, accessory: .selection(selection.contains(artifact.id)), scope: loadedScope)
                    }
                    .buttonStyle(.plain)
                    .disabled(attaching)
                    .accessibilityIdentifier(A11yID.Chat.FilePicker.item(artifact.id))
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.lg)
        }
        .scrollIndicators(.hidden)
    }

    private func toggle(_ artifact: FileItem) {
        if selection.remove(artifact.id) == nil { selection.insert(artifact.id) }
        Haptics.impact(.attachmentChoice)
        Log.ui.info("FilePickerSheet.toggle artifact=\(artifact.id) selected=\(selection.contains(artifact.id))")
    }

    private func attach() {
        Task {
            guard let scope = loadedScope, StorageRoot.currentScope == scope else { return }
            attaching = true
            defer { attaching = false }
            do {
                var picked: [FileItem] = []
                for artifact in artifacts where selection.contains(artifact.id) {
                    picked.append(try await ProfileRepository.shared.materializeFile(artifact, in: scope))
                }
                guard StorageRoot.currentScope == scope else { return }
                Log.ui.info("FilePickerSheet.attach count=\(picked.count)")
                onAttach(picked)
                dismiss()
            } catch is CancellationError {
            } catch {
                Log.ui.error("FilePickerSheet.attach download error=\(error.localizedDescription)")
                attachErrorMessage = error.localizedDescription
            }
        }
    }

    private func load() async {
        guard let scope = StorageRoot.currentScope else {
            artifacts = []
            selection.removeAll()
            loadedScope = nil
            loading = false
            return
        }
        do {
            let loaded = try await ProfileRepository.shared.artifacts(in: scope)
                .filter { !attachedIDs.contains($0.id) }
                .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
            try Task.checkCancellation()
            guard StorageRoot.currentScope == scope else { return }
            if loadedScope != scope { selection.removeAll() }
            loadedScope = scope
            artifacts = loaded
            loadErrorMessage = nil
            loading = false
            Log.ui.info("FilePickerSheet.load count=\(artifacts.count) attached=\(attachedIDs.count)")
        } catch is CancellationError {
        } catch {
            artifacts = []
            selection.removeAll()
            loadedScope = nil
            loading = false
            loadErrorMessage = error.localizedDescription
            Log.ui.error("FilePickerSheet.load profile=\(scope.profileID?.uuidString ?? "nil") error=\(error.localizedDescription)")
        }
    }
}
