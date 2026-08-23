import SwiftUI

struct MemoryEditorView: View {
    let memory: UserMemory

    var body: some View {
        PersonalContextEditor(
            title: "Memory",
            guidance: "Ox reads this before every chat. Keep it short and durable - preferences, who you are, standing instructions. Markdown is fine.",
            editorIdentifier: A11yID.Settings.memoryEditor,
            saveIdentifier: A11yID.Settings.memorySave,
            copyIdentifier: A11yID.Settings.memoryCopy,
            logName: "Memory",
            read: { memory.text },
            write: { memory.text = $0 }
        )
    }
}
