import SwiftUI

struct CharacterEditorView: View {
    let soul: Soul

    var body: some View {
        PersonalContextEditor(
            title: "Character",
            guidance: "Ox's voice - how it talks and carries itself in every chat. Edit to reshape its character. Markdown is fine; clear it to fall back to the default.",
            editorIdentifier: A11yID.Settings.soulEditor,
            saveIdentifier: A11yID.Settings.soulSave,
            copyIdentifier: A11yID.Settings.soulCopy,
            logName: "Soul",
            read: { soul.text },
            write: { soul.text = $0 }
        )
    }
}
