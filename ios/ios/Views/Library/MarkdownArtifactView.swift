import SwiftUI
import UIKit

struct MarkdownArtifactScreen: View {
    let artifact: Artifact
    let scope: ProfileScope?

    var body: some View {
        MarkdownArtifactView(artifact: artifact, scope: scope)
            .navigationTitle(artifact.userFacingName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
    }
}

struct MarkdownArtifactView: View {
    let artifact: Artifact
    let scope: ProfileScope?

    private enum Phase {
        case loading
        case ready(MarkdownArtifactDocument)
        case failed(String)
    }

    private enum Mode {
        case viewing
        case editing
    }

    @State private var phase: Phase = .loading
    @State private var mode: Mode = .viewing
    @State private var draft = ""
    @State private var isSaving = false
    @State private var saveError: String?

    private var isDirty: Bool {
        guard case .ready(let document) = phase else { return false }
        return draft != document.source
    }

    var body: some View {
        ZStack {
            switch phase {
            case .loading:
                CellularAutomatonLoader()
                    .accessibilityLabel("Loading artifact…")
            case .ready(let document):
                switch mode {
                case .viewing:
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                            MarkdownText(document.source)
                        }
                        .frame(maxWidth: Theme.ContainerWidth.readable, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.top, Theme.Spacing.md)
                        .padding(.bottom, Theme.Spacing.xl)
                    }
                    .scrollIndicators(.hidden)
                    .contentShape(Rectangle())
                    .dismissesSelectableTextSelection {
                        Log.ui.info("MarkdownArtifactView.dismissTextSelection filename=\(artifact.fileName)")
                    }
                case .editing:
                    TextEditor(text: $draft)
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.onSurface)
                        .scrollContentBackground(.hidden)
                        .frame(maxWidth: Theme.ContainerWidth.readable)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.md)
                        .accessibilityLabel(artifact.userFacingName)
                        .accessibilityIdentifier(A11yID.Chat.MarkdownArtifact.editor)
                }
            case .failed(let message):
                ContentUnavailableView(
                    "Artifact unavailable",
                    systemImage: artifact.exists ? "exclamationmark.triangle" : "questionmark.folder",
                    description: Text(message)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.chatSurface)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if case .ready(let document) = phase {
                    switch mode {
                    case .viewing:
                        Button("Edit") { edit(document) }
                            .accessibilityIdentifier(A11yID.Chat.MarkdownArtifact.edit)
                    case .editing:
                        Button("Save") { save() }
                            .disabled(isSaving)
                            .accessibilityIdentifier(A11yID.Chat.MarkdownArtifact.save)
                    }
                }
            }
        }
        .task { await load() }
        .alert("Couldn't save note", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private func load() async {
        phase = .loading
        do {
            guard let scope else { throw CocoaError(.fileNoSuchFile) }
            let document = try await ProfileRepository.shared.readMarkdownArtifact(
                named: artifact.fileName,
                in: scope
            )
            guard !Task.isCancelled else { return }
            draft = document.source
            mode = .viewing
            phase = .ready(document)
            Log.ui.info("MarkdownArtifactView.load filename=\(artifact.fileName) bytes=\(document.byteCount)")
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(artifact.userFacingErrorDescription(error))
            Log.ui.error("MarkdownArtifactView.load filename=\(artifact.fileName) error=\(error.localizedDescription)")
        }
    }

    private func edit(_ document: MarkdownArtifactDocument) {
        draft = document.source
        mode = .editing
        Log.ui.info("MarkdownArtifactView.edit filename=\(artifact.fileName)")
        Haptics.impact(.editStarted)
    }

    private func save() {
        guard !isSaving else { return }
        guard isDirty else {
            mode = .viewing
            return
        }
        let source = draft
        isSaving = true
        Task {
            do {
                guard let scope else { throw CocoaError(.fileNoSuchFile) }
                let document = try await ProfileRepository.shared.writeMarkdownArtifact(
                    source,
                    named: artifact.fileName,
                    in: scope
                )
                guard !Task.isCancelled else { return }
                isSaving = false
                draft = document.source
                mode = .viewing
                phase = .ready(document)
                Log.ui.info("MarkdownArtifactView.save filename=\(artifact.fileName) bytes=\(document.byteCount)")
                Haptics.success(.settingsSaved)
            } catch {
                guard !Task.isCancelled else { return }
                isSaving = false
                saveError = artifact.userFacingErrorDescription(error)
                Log.ui.error("MarkdownArtifactView.save filename=\(artifact.fileName) error=\(error.localizedDescription)")
            }
        }
    }
}
