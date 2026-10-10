import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ProfileFilesPicker: UIViewControllerRepresentable {
    let directory: URL
    let onSelection: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelection: onSelection, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: false)
        picker.directoryURL = directory
        picker.shouldShowFileExtensions = true
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        Log.ui.info("ProfileFiles.browser present directory=\(directory.path)")
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onSelection: (URL) -> Void
        private let onCancel: () -> Void

        init(onSelection: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onSelection = onSelection
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { onCancel(); return }
            Log.ui.info("ProfileFiles.browser picked name=\(url.lastPathComponent)")
            onSelection(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

private final class ProfileFileHandoff {
    private enum Phase {
        case browsing
        case selected(URL)
        case dismissed
        case finished
    }

    private var phase = Phase.browsing

    func begin() { phase = .browsing }
    func cancel() { phase = .finished }

    func select(_ url: URL) -> URL? {
        switch phase {
        case .browsing:
            phase = .selected(url)
            return nil
        case .dismissed:
            phase = .finished
            return url
        case .selected, .finished:
            return nil
        }
    }

    func dismiss() -> URL? {
        switch phase {
        case .selected(let url):
            phase = .finished
            return url
        case .browsing:
            phase = .dismissed
            return nil
        case .dismissed, .finished:
            return nil
        }
    }
}

private struct ProfileFilesBrowser: ViewModifier {
    let scope: ProfileScope?
    @Binding var isPresented: Bool
    @State private var handoff = ProfileFileHandoff()
    @State private var preview: ArtifactZoomPreview?
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, onDismiss: {
                if let url = handoff.dismiss() { openSelection(url) }
            }) {
                if let scope {
                    ProfileFilesPicker(directory: scope.root) { url in
                        if let ready = handoff.select(url) { openSelection(ready) }
                        isPresented = false
                    } onCancel: {
                        handoff.cancel()
                        isPresented = false
                        Log.ui.info("ProfileFiles.browser cancelled")
                    }
                    .onAppear { handoff.begin() }
                    .ignoresSafeArea()
                }
            }
            .navigationDestination(item: $preview) { selected in
                if selected.artifact.usesDedicatedPreview {
                    ArtifactNavigationPage(artifact: selected.artifact, scope: selected.scope)
                } else {
                    ArtifactPreviewPresentation(artifact: selected.artifact, scope: selected.scope)
                }
            }
            .alert("Couldn't open file", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private func openSelection(_ url: URL) {
        guard let scope else { return }
        Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let root = scope.root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
                let path = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
                guard path.count > root.count, path.starts(with: root) else {
                    Log.ui.warning("ProfileFiles.browser selection rejected profile=\(scope.profileID?.uuidString ?? "temporary") reason=outsideProfile")
                    errorMessage = String(localized: "Choose a file inside this Profile. Use Add attachment to import a file from another location.")
                    return
                }
                let relative = path.dropFirst(root.count).joined(separator: "/")
                let artifact = try await ProfileRepository.shared.artifact(named: "/" + relative, in: scope)
                try Task.checkCancellation()
                preview = ArtifactZoomPreview(artifact: artifact, sourceID: "profile-files:\(artifact.id)", scope: scope)
                Log.ui.info("ProfileFiles.browser selected profile=\(scope.profileID?.uuidString ?? "temporary") path=\(relative)")
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
                Log.ui.error("ProfileFiles.browser open failed profile=\(scope.profileID?.uuidString ?? "temporary") error=\(error.localizedDescription)")
            }
        }
    }
}

extension View {
    func profileFilesBrowser(scope: ProfileScope?, isPresented: Binding<Bool>) -> some View {
        modifier(ProfileFilesBrowser(scope: scope, isPresented: isPresented))
    }
}
