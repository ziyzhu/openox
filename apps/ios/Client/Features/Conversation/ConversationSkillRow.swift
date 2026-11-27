import SwiftUI

struct ConversationSkillRow: View {
    let skill: Skill
    let accessibilityIdentifier: String

    @State private var skills = Skills.shared
    @State private var presentedSkill: Skill?
    @State private var profileID = StorageRoot.shared.activeId

    private var displayedSkill: Skill {
        skills.all.first { $0.id == skill.id } ?? skill
    }

    var body: some View {
        Button {
            presentedSkill = displayedSkill
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .environment(\.symbolVariants, .none)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .frame(width: 16, height: 20)
                    .accessibilityHidden(true)
                Text(verbatim: "/\(displayedSkill.displayName)")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 240, alignment: .leading)
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .dashedChipOutline()
        }
        .buttonStyle(OxPressedSurfaceButtonStyle())
        .frame(minHeight: Theme.Size.minimumTouchTarget)
        .contentShape(Rectangle())
        .accessibilityLabel(Text(verbatim: "/\(displayedSkill.displayName)"))
        .accessibilityHint(Text(verbatim: displayedSkill.description))
        .accessibilityIdentifier(accessibilityIdentifier)
        .sheet(item: $presentedSkill) { selected in
            NavigationStack {
                ConversationSkillDetails(skill: selected, skills: skills, profileID: profileID)
            }
            .presentationBackground(Theme.Colors.background)
        }
    }
}

struct ConversationSkillDetails: View {
    let skill: Skill
    let skills: Skills
    let profileID: UUID?

    @Environment(\.dismiss) private var dismiss
    @State private var editing: SkillDraft?

    private var currentSkill: Skill? {
        guard let profileID, profileID == StorageRoot.shared.activeId else { return nil }
        return skills.all.first { $0.id == skill.id }
    }

    private var displayedSkill: Skill { currentSkill ?? skill }
    private var identifier: String { A11yID.ConversationControls.Message.skillDetails(skill.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if !displayedSkill.description.isEmpty {
                    Text(verbatim: displayedSkill.description)
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                }
                MarkdownText(displayedSkill.instructions, accessibilityIdentifier: "\(identifier).instructions")
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.lg)
        }
        .scrollIndicators(.hidden)
        .background(Theme.Colors.background)
        .task {
            skills.refresh()
            await skills.waitUntilCurrent()
            Log.ui.info("ConversationSkillDetails opened name=\(skill.name) profile=\(profileID?.uuidString ?? "none") active=\(StorageRoot.shared.activeId?.uuidString ?? "none") editable=\(currentSkill?.owner.isWritable ?? false)")
        }
        .navigationTitle(displayedSkill.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Back", systemImage: "chevron.left") { dismiss() }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("\(identifier).back")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let currentSkill, currentSkill.owner.isWritable {
                    Button("Edit", systemImage: "square.and.pencil") {
                        editing = SkillDraft(currentSkill)
                    }
                    .labelStyle(.iconOnly)
                    .environment(\.symbolVariants, .none)
                    .accessibilityIdentifier("\(identifier).edit")
                }
            }
        }
        .navigationDestination(item: $editing) { draft in
            SkillEditorView(draft: draft, skills: skills, profileID: profileID)
                .id(draft.id)
        }
    }
}
