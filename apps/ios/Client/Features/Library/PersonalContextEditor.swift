import SwiftUI

struct PersonalContextEditor: View {
    let title: LocalizedStringKey
    let guidance: LocalizedStringKey
    let editorIdentifier: String
    let saveIdentifier: String
    let copyIdentifier: String
    let logName: String
    let read: () -> String
    let write: (String) -> Void

    @State private var draft = ""
    @State private var copyFeedback = CopyFeedback()
    @FocusState private var isFocused: Bool

    private var dirty: Bool { draft != read() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text(guidance)
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)

                TextEditor(text: $draft)
                    .focused($isFocused)
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 280, alignment: .topLeading)
                    .padding(Theme.Spacing.sm)
                    .settingsSurface()
                    .accessibilityIdentifier(editorIdentifier)
            }
            .padding(Theme.Spacing.lg)
        }
        .scrollIndicators(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { save() } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!dirty)
                    .accessibilityIdentifier(saveIdentifier)

                    Button { copy() } label: {
                        Label(
                            copyFeedback.didCopy ? "Copied" : "Copy",
                            systemImage: copyFeedback.didCopy ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .disabled(draft.isEmpty)
                    .accessibilityIdentifier(copyIdentifier)
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .onAppear { draft = read() }
        .onDisappear { if dirty { save() } }
    }

    private func copy() {
        copyFeedback.copy(draft, logMessage: "\(logName).copy chars=\(draft.count)")
    }

    private func save() {
        Log.ui.info("\(logName).save chars=\(draft.count)")
        write(draft)
        isFocused = false
    }
}
