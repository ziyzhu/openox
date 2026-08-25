import SwiftUI

struct SkillImportView: View {
    let proposal: SkillImportProposal
    let coordinator: SkillImportCoordinator
    @State private var skills: Skills = .shared

    private var hasConflict: Bool {
        skills.skill(named: proposal.skill.name) != nil
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    LibraryDestinationIcon(.skills)
                        .foregroundStyle(Theme.Colors.onSurface)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(verbatim: "/\(proposal.skill.name)")
                            .font(Theme.Fonts.title)
                            .foregroundStyle(Theme.Colors.onSurface)
                        Text(verbatim: proposal.skill.description)
                            .font(Theme.Fonts.bodyMd)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(A11yID.SkillImport.preview)

                if proposal.skill.services.isEmpty {
                    Label("No plugins requested", systemImage: "checkmark.shield")
                        .font(Theme.Fonts.bodySm)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                } else {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text("Requested plugins")
                            .font(Theme.Fonts.labelMd)
                            .foregroundStyle(Theme.Colors.onSurface)
                        ForEach(proposal.skill.services, id: \.self) { domain in
                            Label(domain, systemImage: "globe")
                                .font(Theme.Fonts.bodySm)
                                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                        }
                    }
                }

                if hasConflict {
                    Text("A skill named /\(proposal.skill.name) already exists.")
                        .font(Theme.Fonts.bodySm)
                        .foregroundStyle(Theme.Colors.error)
                }

                Spacer(minLength: 0)

                VStack(spacing: Theme.Spacing.sm) {
                    if hasConflict {
                        Button("Replace Skill", role: .destructive) {
                            coordinator.install(.replace)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.Colors.error)
                        .accessibilityIdentifier(A11yID.SkillImport.replace)

                        Button("Save a Copy") {
                            coordinator.install(.copy)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier(A11yID.SkillImport.copy)
                    } else {
                        Button("Add Skill") {
                            coordinator.install(.add)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier(A11yID.SkillImport.add)
                    }
                }
                .frame(maxWidth: .infinity)
                .disabled(coordinator.isSaving)
            }
            .padding(Theme.Spacing.lg)
            .background(Theme.Colors.background)
            .navigationTitle("Add Skill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { coordinator.dismissProposal() }
                        .disabled(coordinator.isSaving)
                        .accessibilityIdentifier(A11yID.SkillImport.cancel)
                }
            }
            .overlay {
                if coordinator.isSaving {
                    Rectangle()
                        .fill(Theme.Colors.background.opacity(0.65))
                        .ignoresSafeArea()
                    CellularAutomatonLoader(tint: Theme.Colors.onSurface.dynamic)
                }
            }
            .onAppear { skills.refresh() }
        }
    }
}
