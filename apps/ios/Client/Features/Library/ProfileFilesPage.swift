import SwiftUI
import QuickLook

struct ProfileFilesPage: View {
    let scope: ProfileScope
    @State private var store = DeviceFolderStore.shared
    @State private var profileFolderPresented = false
    @State private var browsing: MountedFolder?
    @State private var handoff = ProfileFileHandoff()
    @State private var previewFile: PreviewFile?
    @State private var operation: String?
    @State private var errorMessage: String?

    private struct MountedFolder: Identifiable {
        let id: String
        let root: URL
    }

    private struct PreviewFile: Identifiable {
        let id = UUID()
        let url: URL
    }

    private var mounts: [DeviceFolderStore.Grant] { store.grants(for: scope.profileID) }
    private var unassigned: [DeviceFolderStore.Grant] { store.grants.filter { $0.profileId == nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                SettingsSection("Profile", layout: .row) {
                    Button { profileFolderPresented = true } label: {
                        SettingsDisclosureRow(title: "Profile folder", value: Text(""))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("profile.files.profileFolder")
                }
                SettingsSection(
                    "Mounted folders",
                    footer: "Folders stay in their original location. Only this Profile can access them on this device.",
                    layout: mounts.isEmpty ? .row : .group
                ) {
                    VStack(spacing: 0) {
                        ForEach(Array(mounts.enumerated()), id: \.element.id) { index, grant in
                            if index > 0 { Divider().settingsContentInset() }
                            mountRow(grant)
                        }
                        if !mounts.isEmpty { Divider().settingsContentInset() }
                        Button { perform("mount") { profileId in
                            let url = try await HostFolderPicker.choose()
                            _ = try HostProfileCommands.profile(profileId.uuidString)
                            try await store.add(url, profileId: profileId)
                        } } label: {
                            HStack(spacing: Theme.Spacing.md) {
                                Image(systemName: "plus")
                                    .font(.system(.body, weight: .medium))
                                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                                    .frame(width: 24)
                                Text("Add folder")
                                    .font(Theme.Fonts.bodyMd)
                                    .foregroundStyle(Theme.Colors.onSurface)
                                Spacer(minLength: 0)
                            }
                            .settingsRowPadding()
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("profile.files.addFolder")
                    }
                }
                if !unassigned.isEmpty {
                    SettingsSection("Unassigned folders", layout: unassigned.count == 1 ? .row : .group) {
                        VStack(spacing: 0) {
                            ForEach(Array(unassigned.enumerated()), id: \.element.id) { index, grant in
                                if index > 0 { Divider().settingsContentInset() }
                                Button { perform(grant.id) { profileId in
                                    try await store.assign(grant.id, profileId: profileId)
                                } } label: {
                                    SettingsDisclosureRow(title: LocalizedStringKey(grant.name), value: Text("Use in this Profile"))
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("profile.files.assign.\(grant.id)")
                            }
                        }
                    }
                }
            }
            .settingsPagePadding()
        }
        .disabled(operation != nil || scope.profileID == nil)
        .scrollIndicators(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
        .profileFilesBrowser(scope: scope, isPresented: $profileFolderPresented)
        .sheet(item: $browsing, onDismiss: {
            if let url = handoff.dismiss() { openSelection(url) }
        }) { folder in
            ProfileFilesPicker(directory: folder.root) { url in
                if let ready = handoff.select(url) { openSelection(ready) }
                browsing = nil
            } onCancel: {
                handoff.cancel()
                browsing = nil
            }
            .onAppear { handoff.begin() }
            .ignoresSafeArea()
        }
        .sheet(item: $previewFile) { file in
            MountedFilePreview(url: file.url)
                .ignoresSafeArea()
                .onDisappear { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        }
        .alert("Couldn't access folder", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) { errorMessage = nil } } message: {
            Text(errorMessage ?? "")
        }
    }

    private func mountRow(_ grant: DeviceFolderStore.Grant) -> some View {
        let unavailable = mountError(grant)
        return Button {
            do {
                let root = try store.repositoryRoot(grantID: grant.id, relativePath: [], profileId: scope.profileID)
                browsing = MountedFolder(id: grant.id, root: root)
            } catch { errorMessage = error.localizedDescription }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                SettingsDisclosureRow(title: LocalizedStringKey(grant.name), value: Text(""), icon: "folder")
                if let unavailable {
                    Text(unavailable)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                        .settingsContentInset()
                        .padding(.bottom, SettingsLayout.rowVerticalInset)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("profile.files.mount.\(grant.id)")
    }

    private func perform(_ name: String, action: @escaping @MainActor (UUID) async throws -> Void) {
        guard operation == nil, let profileId = scope.profileID else { return }
        operation = name
        Task {
            defer { operation = nil }
            do { try await action(profileId) }
            catch {
                errorMessage = error.localizedDescription
                Log.ui.error("ProfileFiles operation=\(name) profile=\(profileId) error=\(error.localizedDescription)")
            }
        }
    }

    private func openSelection(_ selectedFile: URL) {
        let profileId = scope.profileID
        Task {
            do {
                guard let grant = mounts.first(where: { grant in
                    guard let root = try? store.repositoryRoot(grantID: grant.id, relativePath: [], profileId: profileId) else { return false }
                    return selectedFile.standardizedFileURL.pathComponents.starts(with: root.standardizedFileURL.pathComponents)
                }) else { throw DeviceFolderStore.StoreError.invalidPath(selectedFile.lastPathComponent) }
                let root = try store.repositoryRoot(grantID: grant.id, relativePath: [], profileId: profileId)
                let relative = Array(selectedFile.standardizedFileURL.pathComponents.dropFirst(root.standardizedFileURL.pathComponents.count))
                let snapshot = try await store.coordinate(grantID: grant.id, relativePath: relative, profileId: profileId, mode: .read) { url in
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 32 * 1024 * 1024 else { throw RuntimeError.bridge("File is too large to preview") }
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let snapshot = directory.appendingPathComponent(url.lastPathComponent)
                    do { try FileManager.default.copyItem(at: url, to: snapshot) }
                    catch { try? FileManager.default.removeItem(at: directory); throw error }
                    return snapshot
                }
                previewFile = PreviewFile(url: snapshot)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func mountError(_ grant: DeviceFolderStore.Grant) -> String? {
        do {
            _ = try store.repositoryRoot(grantID: grant.id, relativePath: [], profileId: scope.profileID)
            return nil
        } catch { return error.localizedDescription }
    }
}

private struct MountedFilePreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}
