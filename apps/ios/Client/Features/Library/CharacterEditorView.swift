import SwiftUI

struct CharacterEditorView: View {
    let soul: Soul

    private var sectionHeader: String {
        guard let range = soul.text.range(of: #"\A## Voice\r?\n(?:\r?\n)*"#, options: .regularExpression) else { return "" }
        return String(soul.text[range])
    }

    private var editableText: String {
        String(soul.text.dropFirst(sectionHeader.count))
    }

    var body: some View {
        PersonalContextEditor(
            title: "Voice",
            guidance: "Ox's voice - how it talks and carries itself in every conversation. Edit to reshape its voice. Markdown is fine; clear it to fall back to the default.",
            editorIdentifier: A11yID.Settings.soulEditor,
            saveIdentifier: A11yID.Settings.soulSave,
            copyIdentifier: A11yID.Settings.soulCopy,
            logName: "Soul",
            read: { editableText },
            write: { soul.text = $0.isEmpty ? "" : sectionHeader + $0 }
        )
    }
}
