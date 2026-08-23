import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

private struct ArtifactRecord: Identifiable, Sendable {
    let artifact: Artifact
    let isSaved: Bool

    var id: String { artifact.id }
}

private struct SidebarSafeArtifactButton<Label: View>: View {
    let artifact: Artifact
    let action: () -> Void
    let label: Label

    @Environment(\.sidebarInteraction) private var sidebarInteraction

    init(
        artifact: Artifact,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.artifact = artifact
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button {
            guard !sidebarInteraction.dragActive else {
                Log.ui.info("ArtifactsView.preview suppressed=sidebarDrag file=\(artifact.fileName)")
                return
            }
            action()
        } label: {
            label
        }
    }
}

struct ArtifactsView: View {
    let emptyStateReady: Bool
    let refreshEpoch: Int
    let onClose: () -> Void
    let onRename: (Artifact, String) async throws -> Artifact
    let onDelete: (Artifact) async throws -> Void

    private enum ArtifactTab: String, CaseIterable, Identifiable {
        case saved
        case all

        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .saved: "Saved"
            case .all: "All"
            }
        }
    }

    private enum ArtifactFilter: String, CaseIterable, Identifiable {
        case all
        case images
        case documents

        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .all: "All types"
            case .images: "Images"
            case .documents: "Documents"
            }
        }
    }

    private enum ArtifactSort: String, CaseIterable, Identifiable {
        case name
        case modified
        case size
        case type

        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .name: "Name"
            case .modified: "Date modified"
            case .size: "Size"
            case .type: "Type"
            }
        }
    }

    @State private var records: [ArtifactRecord] = []
    @State private var displayedRecords: [ArtifactRecord] = []
    @State private var preview: ArtifactZoomPreview?
    @State private var dedicatedPreview: Artifact?
    @State private var loading = true
    @State private var query = ""
    @State private var tab: ArtifactTab = .saved
    @State private var filter: ArtifactFilter = .all
    @State private var sort: ArtifactSort = .modified
    @State private var descending = true
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var photosPresented = false
    @State private var filesPresented = false
    @State private var cameraPresented = false
    @State private var errorMessage: String?
    @State private var renaming: Artifact?
    @State private var renameDraft = ""
    @State private var renameErrorMessage: String?
    @State private var pendingDelete: Artifact?
    @State private var deleteErrorMessage: String?
    @State private var savedErrorMessage: String?
    @State private var downloadErrorMessage: String?
    @State private var downloadingIDs: Set<String> = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    if loading {
                        if emptyStateReady {
                            ContentLoadingView(label: "Loading artifacts…")
                        } else {
                            Color.clear
                        }
                    } else if records.isEmpty {
                        ScrollView {
                            VStack(spacing: Theme.Spacing.sm) {
                                LibraryEmptyNote(
                                    destination: .artifacts,
                                    title: "No artifacts yet",
                                    detail: "Add a file or photo, or ask Ox to create something in a chat."
                                )
                            }
                            .padding(.horizontal, Theme.Spacing.lg)
                            .padding(.bottom, Theme.Spacing.lg)
                            .opacity(emptyStateReady ? 1 : 0)
                            .accessibilityHidden(!emptyStateReady)
                        }
                        .scrollIndicators(.hidden)
                    } else if displayedRecords.isEmpty && tab == .saved && query.isEmpty {
                        ScrollView {
                            LibraryEmptyNote(
                                destination: .artifacts,
                                title: "No saved artifacts",
                                detail: "Long press an artifact in All files to save it."
                            )
                            .padding(.horizontal, Theme.Spacing.lg)
                            .padding(.bottom, Theme.Spacing.lg)
                            .opacity(emptyStateReady ? 1 : 0)
                            .accessibilityHidden(!emptyStateReady)
                        }
                        .scrollIndicators(.hidden)
                    } else if displayedRecords.isEmpty && emptyStateReady {
                        ContentUnavailableView.search(text: query)
                    } else if displayedRecords.isEmpty {
                        Color.clear
                    } else {
                        ScrollView {
                            LazyVStack(spacing: Theme.Spacing.sm) {
                                ForEach(displayedRecords) { record in
                                    let artifact = downloadingIDs.contains(record.id)
                                        ? record.artifact.updatingAvailability(.downloading)
                                        : record.artifact
                                    SidebarSafeArtifactButton(
                                        artifact: record.artifact,
                                        action: { open(record.artifact) }
                                    ) {
                                        ArtifactLibraryRow(
                                            artifact: artifact,
                                            accessory: .none,
                                            showsContainer: false,
                                            horizontalPadding: 0,
                                            verticalPadding: Theme.Spacing.xs
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(downloadingIDs.contains(record.id))
                                    .accessibilityLabel(artifact.userFacingAccessibilityLabel)
                                    .accessibilityIdentifier(A11yID.Artifacts.item(record.id))
                                    .contextMenuPreviewShape()
                                    .contextMenu {
                                        ArtifactContextMenu(
                                            artifact: artifact,
                                            canMutate: artifact.availability == .local,
                                            onRename: {
                                                renameDraft = record.artifact.userFacingName
                                                renaming = record.artifact
                                            },
                                            onDelete: { pendingDelete = record.artifact },
                                            isSaved: record.isSaved,
                                            onToggleSaved: { toggleSaved(record) }
                                        )
                                    } preview: {
                                        ArtifactContextMenuPreview(artifact: record.artifact)
                                    }
                                }
                            }
                            .padding(.horizontal, Theme.Spacing.lg)
                            .padding(.bottom, Theme.Spacing.lg)
                        }
                        .scrollIndicators(.hidden)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .safeAreaBar(edge: .top, spacing: 0) {
                artifactControls
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.bottom, Theme.Spacing.sm)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(emptyStateReady ? A11yID.Artifacts.ready : A11yID.Artifacts.transitioning)
                    .id(emptyStateReady)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .background(Theme.Colors.background)
            .navigationTitle("Artifacts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SheetDismissToolbarButton(action: onClose)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    addMenu
                }
            }
            .searchable(text: $query, prompt: "Search artifacts")
            .navigationDestination(isPresented: dedicatedPreviewPresented) {
                if let artifact = dedicatedPreview {
                    ArtifactNavigationPage(artifact: artifact)
                        .onAppear {
                            Log.ui.info("ArtifactsView.navigation present file=\(artifact.fileName)")
                        }
                        .onDisappear {
                            Log.ui.info("ArtifactsView.navigation return file=\(artifact.fileName)")
                        }
                }
            }
            .navigationDestination(item: $preview) { selected in
                ArtifactPreviewPresentation(artifact: selected.artifact)
                .toolbar(removing: .search)
                .onAppear {
                    Log.ui.info("ArtifactsView.navigation present file=\(selected.artifact.fileName)")
                }
                .onDisappear {
                    Log.ui.info("ArtifactsView.navigation return file=\(selected.artifact.fileName)")
                }
            }
        }
        .task(id: refreshEpoch) { await load() }
        .onChange(of: query) { _, _ in updateDisplayedRecords() }
        .onChange(of: tab) { _, _ in updateDisplayedRecords() }
        .onChange(of: filter) { _, _ in updateDisplayedRecords() }
        .onChange(of: sort) { _, _ in updateDisplayedRecords() }
        .onChange(of: descending) { _, _ in updateDisplayedRecords() }
        .photosPicker(isPresented: $photosPresented, selection: $photoPickerItems, maxSelectionCount: 10, matching: .images)
        .onChange(of: photoPickerItems) { _, items in
            guard !items.isEmpty else { return }
            photoPickerItems = []
            importPhotos(items)
        }
        .fileImporter(isPresented: $filesPresented, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importFiles(urls)
            case .failure(let error):
                Log.ui.error("ArtifactsView.files error=\(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
        }
        .fullScreenCover(isPresented: $cameraPresented) {
            CameraPicker { image in
                if let image { importCamera(image) }
            }
            .ignoresSafeArea()
        }
        .alert("Couldn't add artifact", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .artifactMutationAlerts(
            renaming: $renaming,
            renameDraft: $renameDraft,
            renameError: $renameErrorMessage,
            deleting: $pendingDelete,
            deleteError: $deleteErrorMessage,
            onRename: rename,
            onDelete: delete
        )
        .alert("Couldn't update artifact", isPresented: Binding(
            get: { savedErrorMessage != nil },
            set: { if !$0 { savedErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { savedErrorMessage = nil }
        } message: {
            Text(savedErrorMessage ?? "")
        }
        .alert("Couldn't download artifact", isPresented: Binding(
            get: { downloadErrorMessage != nil },
            set: { if !$0 { downloadErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { downloadErrorMessage = nil }
        } message: {
            Text(downloadErrorMessage ?? "")
        }
    }

    private var dedicatedPreviewPresented: Binding<Bool> {
        Binding(
            get: { dedicatedPreview != nil },
            set: { presented in
                if !presented { dedicatedPreview = nil }
            }
        )
    }

    private func open(_ artifact: Artifact) {
        Task {
            guard let scope = StorageRoot.currentScope else { return }
            downloadingIDs.insert(artifact.id)
            defer { downloadingIDs.remove(artifact.id) }
            do {
                let available = try await ProfileRepository.shared.materializeArtifact(artifact, in: scope)
                guard StorageRoot.currentScope == scope else { return }
                Log.ui.info("ArtifactsView.preview present file=\(available.fileName)")
                if available.usesDedicatedPreview {
                    dedicatedPreview = available
                } else {
                    preview = ArtifactZoomPreview(
                        artifact: available,
                        sourceID: "artifacts:\(available.id)"
                    )
                }
            } catch is CancellationError {
            } catch {
                Log.ui.error("ArtifactsView.preview download file=\(artifact.fileName) error=\(error.localizedDescription)")
                downloadErrorMessage = error.localizedDescription
            }
        }
    }

    private var artifactControls: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(ArtifactTab.allCases) { option in
                Button {
                    Haptics.impact(.artifactTabSelected)
                    tab = option
                } label: {
                    Text(option.title)
                        .frame(minWidth: 48)
                }
                .buttonStyle(OxChipButton(filled: tab == option))
                .accessibilityAddTraits(tab == option ? .isSelected : [])
                .accessibilityIdentifier(A11yID.Artifacts.filter(option.rawValue))
            }
            Spacer()
            filterAndSortMenu
        }
    }

    private var addMenu: some View {
        Menu {
            Button {
                filesPresented = true
            } label: {
                Label("Files", systemImage: "folder")
            }
            .accessibilityIdentifier(A11yID.Artifacts.addFiles)
            Button {
                photosPresented = true
            } label: {
                Label("Photos", systemImage: "photo.on.rectangle")
            }
            .accessibilityIdentifier(A11yID.Artifacts.addPhotos)
            Button {
                guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                    errorMessage = String(localized: "This device has no camera.")
                    return
                }
                cameraPresented = true
            } label: {
                Label("Camera", systemImage: "camera")
            }
            .accessibilityIdentifier(A11yID.Artifacts.addCamera)
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("Add artifact")
        .accessibilityIdentifier(A11yID.Artifacts.add)
    }

    private var filterAndSortMenu: some View {
        Menu {
            Section("Filter") {
                ForEach(ArtifactFilter.allCases) { option in
                    Button { filter = option } label: {
                        Label(option.title, systemImage: filter == option ? "checkmark" : filterIcon(option))
                    }
                    .accessibilityIdentifier(A11yID.Artifacts.filter(option.rawValue))
                }
            }
            Section("Sort by") {
                ForEach(ArtifactSort.allCases) { option in
                    Button { sort = option } label: {
                        Label(option.title, systemImage: sort == option ? "checkmark" : sortIcon(option))
                    }
                }
                Button { descending.toggle() } label: {
                    Label(descending ? "Descending" : "Ascending", systemImage: descending ? "arrow.down" : "arrow.up")
                }
            }
        } label: {
            Image(systemName: filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.Colors.onSurface)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filter and sort artifacts")
        .accessibilityValue(Text(filter.title))
        .accessibilityIdentifier(A11yID.Artifacts.filterAndSort)
    }

    private func updateDisplayedRecords() {
        displayedRecords = records
            .filter { record in
                let matchesQuery = query.isEmpty || record.artifact.userFacingName.localizedCaseInsensitiveContains(query)
                let matchesTab = tab == .all || record.isSaved
                let matchesFilter = switch filter {
                case .all: true
                case .images: record.artifact.kind == .image
                case .documents: record.artifact.kind != .image
                }
                return matchesQuery && matchesTab && matchesFilter
            }
            .sorted { left, right in
                let comparison = comparison(left.artifact, right.artifact)
                return descending ? comparison == .orderedDescending : comparison == .orderedAscending
            }
    }

    private func comparison(_ left: Artifact, _ right: Artifact) -> ComparisonResult {
        switch sort {
        case .name:
            left.userFacingName.localizedStandardCompare(right.userFacingName)
        case .modified:
            compare(left.modifiedAt ?? .distantPast, right.modifiedAt ?? .distantPast)
        case .size:
            compare(left.size ?? 0, right.size ?? 0)
        case .type:
            (left.userFacingTypeName ?? left.kind.rawValue)
                .localizedStandardCompare(right.userFacingTypeName ?? right.kind.rawValue)
        }
    }

    private func compare<T: Comparable>(_ left: T, _ right: T) -> ComparisonResult {
        if left < right { return .orderedAscending }
        if left > right { return .orderedDescending }
        return .orderedSame
    }

    private func filterIcon(_ option: ArtifactFilter) -> String {
        switch option {
        case .all: "tray.full"
        case .images: "photo"
        case .documents: "doc"
        }
    }

    private func sortIcon(_ option: ArtifactSort) -> String {
        switch option {
        case .name: "textformat"
        case .modified: "calendar"
        case .size: "arrow.up.arrow.down"
        case .type: "square.grid.2x2"
        }
    }

    private func load() async {
        guard let scope = StorageRoot.currentScope else {
            records = []
            displayedRecords = []
            loading = false
            return
        }
        let repository = ProfileRepository.shared
        let savedNames = await repository.savedArtifactNames(in: scope)
        records = await repository.artifacts(in: scope)
            .map { artifact in
                ArtifactRecord(
                    artifact: artifact,
                    isSaved: savedNames.contains { $0.caseInsensitiveCompare(artifact.fileName) == .orderedSame }
                )
            }
        updateDisplayedRecords()
        loading = false
        Log.ui.info("ArtifactsView.load count=\(records.count)")
    }

    private func toggleSaved(_ record: ArtifactRecord) {
        Task {
            do {
                guard let scope = StorageRoot.currentScope else { return }
                try await ProfileRepository.shared.setArtifactSaved(
                    !record.isSaved,
                    named: record.artifact.fileName,
                    in: scope
                )
                await load()
            } catch {
                Log.ui.error("ArtifactsView.saved file=\(record.artifact.fileName) error=\(error.localizedDescription)")
                savedErrorMessage = error.localizedDescription
            }
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        Task {
            do {
                for (index, item) in items.enumerated() {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw ArtifactError.imageDecodeFailed
                    }
                    _ = try await ArtifactImporter.importImageDataAsync(data, suggestedName: "Photo \(index + 1).jpg")
                }
                await load()
            } catch {
                Log.ui.error("ArtifactsView.photos error=\(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importFiles(_ urls: [URL]) {
        Task {
            do {
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    _ = try await ArtifactImporter.importFileAsync(at: url)
                }
                await load()
            } catch {
                Log.ui.error("ArtifactsView.import error=\(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importCamera(_ image: UIImage) {
        Task {
            do {
                _ = try await ArtifactImporter.importImageAsync(image, suggestedName: "Camera.jpg")
                await load()
            } catch {
                Log.ui.error("ArtifactsView.camera error=\(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
        }
    }

    private func rename(_ artifact: Artifact, to newFilename: String) {
        Task {
            do {
                let renamed = try await onRename(artifact, newFilename)
                await load()
                Log.ui.info("ArtifactsView.rename from=\(artifact.fileName) to=\(renamed.fileName)")
            } catch {
                Log.ui.error("ArtifactsView.rename from=\(artifact.fileName) error=\(error.localizedDescription)")
                renameErrorMessage = artifact.userFacingErrorDescription(error)
            }
        }
    }

    private func delete(_ artifact: Artifact) {
        Task {
            do {
                try await onDelete(artifact)
                await load()
                Log.ui.info("ArtifactsView.delete file=\(artifact.fileName)")
            } catch {
                Log.ui.error("ArtifactsView.delete file=\(artifact.fileName) error=\(error.localizedDescription)")
                deleteErrorMessage = artifact.userFacingErrorDescription(error)
            }
        }
    }
}
