import SwiftUI

struct ConversationSkillRow: View {
    let skill: Skill
    let accessibilityIdentifier: String

    @State private var skills = Skills.shared
    @State private var presentedSkill: Skill?
    @State private var profileID: UUID?

    private var displayedSkill: Skill {
        skills.all.first { $0.id == skill.id } ?? skill
    }

    var body: some View {
        Button {
            profileID = StorageRoot.shared.activeId
            presentedSkill = displayedSkill
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "doc.text")
                    .environment(\.symbolVariants, .none)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "/\(displayedSkill.displayName)")
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.onSurface)
                    if !displayedSkill.description.isEmpty {
                        Text(verbatim: displayedSkill.description)
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .conversationCardOutline(cornerRadius: Theme.Radius.xl)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.xl))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
        .sheet(item: $presentedSkill) { selected in
            NavigationStack {
                ConversationSkillDetails(skill: selected, skills: skills, profileID: profileID)
            }
            .presentationBackground(Theme.Colors.background)
        }
    }
}

private struct ConversationSkillDetails: View {
    let skill: Skill
    let skills: Skills
    let profileID: UUID?

    @Environment(\.dismiss) private var dismiss
    @State private var editing: SkillDraft?

    private var currentSkill: Skill? {
        guard profileID == StorageRoot.shared.activeId else { return nil }
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
