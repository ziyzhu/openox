import SwiftUI
import UIKit

struct MarkdownFileScreen: View {
    @State private var file: FileItem
    let scope: ProfileScope?

    init(file: FileItem, scope: ProfileScope?) {
        _file = State(initialValue: file)
        self.scope = scope
    }

    var body: some View {
        MarkdownFileView(file: $file, scope: scope)
            .navigationTitle(file.userFacingName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
    }
}

struct MarkdownFileView: View {
    @Binding var file: FileItem
    let scope: ProfileScope?

    private enum Phase {
        case loading
        case ready(MarkdownFileDocument)
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
                    .accessibilityLabel("Loading file…")
            case .ready(let document):
                switch mode {
                case .viewing:
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                            MarkdownText(document.source, accessibilityIdentifier: "file.\(file.id)")
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
                        Log.ui.info("MarkdownFileView.dismissTextSelection filename=\(file.fileName)")
                    }
                case .editing:
                    TextEditor(text: $draft)
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.onSurface)
                        .scrollContentBackground(.hidden)
                        .frame(maxWidth: Theme.ContainerWidth.readable)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.md)
                        .accessibilityLabel(file.userFacingName)
                        .accessibilityIdentifier(A11yID.ConversationControls.MarkdownFile.editor)
                }
            case .failed(let message):
                ContentUnavailableView(
                    "File unavailable",
                    systemImage: file.exists ? "exclamationmark.triangle" : "questionmark.folder",
                    description: Text(message)
                )
            }
        }
        .interactiveDismissDisabled(mode == .editing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.conversationSurface)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if case .ready(let document) = phase {
                    switch mode {
                    case .viewing:
                        Button("Edit") { edit(document) }
                            .accessibilityIdentifier(A11yID.ConversationControls.MarkdownFile.edit)
                    case .editing:
                        Button("Save") { save() }
                            .disabled(isSaving)
                            .accessibilityIdentifier(A11yID.ConversationControls.MarkdownFile.save)
                    }
                }
            }
        }
        .task { await load() }
        .alert("Couldn't save Markdown", isPresented: Binding(
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
            guard let scope = FilePreviewSource(file: file, scope: scope).scope else { throw CocoaError(.fileReadNoPermission) }
            let document = try await ProfileRepository.shared.readMarkdownFile(
                named: file.fileName,
                in: scope
            )
            guard !Task.isCancelled else { return }
            draft = document.source
            mode = .viewing
            phase = .ready(document)
            Log.ui.info("MarkdownFileView.load filename=\(file.fileName) bytes=\(document.byteCount)")
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
            Log.ui.error("MarkdownFileView.load filename=\(file.fileName) error=\(error.localizedDescription)")
        }
    }

    private func edit(_ document: MarkdownFileDocument) {
        draft = document.source
        mode = .editing
        Log.ui.info("MarkdownFileView.edit filename=\(file.fileName)")
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
                guard let scope = FilePreviewSource(file: file, scope: scope).scope else { throw CocoaError(.fileReadNoPermission) }
                let published = try await ProfileRepository.shared.writeMarkdownFile(
                    source,
                    named: file.fileName,
                    in: scope
                )
                guard !Task.isCancelled else { return }
                file = published
                isSaving = false
                draft = source
                mode = .viewing
                let document = MarkdownFileDocument(source: source, byteCount: source.utf8.count)
                phase = .ready(document)
                Log.ui.info("MarkdownFileView.save filename=\(published.fileName) bytes=\(document.byteCount)")
                Haptics.success(.settingsSaved)
            } catch {
                guard !Task.isCancelled else { return }
                isSaving = false
                saveError = error.localizedDescription
                Log.ui.error("MarkdownFileView.save filename=\(file.fileName) error=\(error.localizedDescription)")
            }
        }
    }
}
