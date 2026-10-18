import SwiftUI
import UniformTypeIdentifiers

struct ProfileCreationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var parent: URL?
    @State private var choosingLocation = false
    @State private var errorMessage: String?
    private var storage: StorageRoot { .shared }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: SettingsLayout.sectionSpacing) {
                    SettingsSection(layout: .group) {
                        VStack(alignment: .leading, spacing: 0) {
                            TextField("Profile name", text: $name)
                                .settingsRowPadding()
                                .accessibilityIdentifier("settings.profileCreate.name")
                            Divider().settingsContentInset()
                            Button { choosingLocation = true } label: {
                                SettingsDisclosureRow(title: "Save in", value: Text(verbatim: parent?.lastPathComponent ?? String(localized: "On this device")))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("settings.profileCreate.location")
                            if parent != nil {
                                Divider().settingsContentInset()
                                Button("Use On This Device") { parent = nil }
                                    .settingsRowPadding()
                                    .accessibilityIdentifier("settings.profileCreate.local")
                            }
                        }
                    }
                }
                .settingsPagePadding()
            }
            .background(Theme.Colors.background)
            .navigationTitle("New Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(storage.isBusy)
                        .accessibilityIdentifier("settings.profileCreate.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            do {
                                try await storage.createProfile(name: name, parent: parent)
                                dismiss()
                            } catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || storage.isBusy)
                    .accessibilityIdentifier("settings.profileCreate.confirm")
                }
            }
            .interactiveDismissDisabled(storage.isBusy)
            .fileImporter(isPresented: $choosingLocation, allowedContentTypes: [.folder]) { result in
                do {
                    let url = try result.get()
                    try storage.accessDirectory(url)
                    parent = url
                } catch { errorMessage = error.localizedDescription }
            }
            .alert("Couldn't create Profile", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }
}
