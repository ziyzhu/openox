import SwiftUI

struct ServiceImportView: View {
    let proposal: ServiceImportProposal
    let coordinator: ServiceImportCoordinator

    private var definition: ServiceDefinition { proposal.payload.definition }

    private var hasLocalService: Bool {
        coordinator.manager.repositories.first(where: { $0.id == ServiceRepository.localID })?
            .services.contains(where: { $0.runtimeID == proposal.payload.domain }) == true
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(verbatim: definition.name)
                            .font(Theme.Fonts.title)
                        Text(verbatim: proposal.payload.domain)
                            .font(Theme.Fonts.bodySm)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                        Text(verbatim: definition.description)
                            .font(Theme.Fonts.bodyMd)
                    }

                    if !definition.actions.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Text("Actions").font(Theme.Fonts.labelMd)
                            ForEach(definition.actions) { action in
                                Text(verbatim: action.label).font(Theme.Fonts.bodyMd)
                            }
                        }
                    }

                    if !definition.skills.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Text("Skills").font(Theme.Fonts.labelMd)
                            ForEach(definition.skills, id: \.name) { skill in
                                Text(verbatim: skill.name).font(Theme.Fonts.bodyMd)
                            }
                        }
                    }

                    Text("Service permissions and sign-in are set up on this device.")
                        .font(Theme.Fonts.bodySm)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)

                    if hasLocalService {
                        Text("A Local service with this ID already exists. Replacing it changes its source.")
                            .font(Theme.Fonts.bodySm)
                            .foregroundStyle(Theme.Colors.error)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.lg)
            }
            .background(Theme.Colors.background)
            .safeAreaInset(edge: .bottom) {
                Button(hasLocalService ? "Replace Service" : "Add Service") {
                    coordinator.install(replacing: hasLocalService)
                }
                .buttonStyle(.borderedProminent)
                .tint(hasLocalService ? Theme.Colors.error : Theme.Colors.primary)
                .disabled(coordinator.isSaving)
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity)
                .background(Theme.Colors.background)
            }
            .navigationTitle("Import Service")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { coordinator.dismissProposal() }
                        .disabled(coordinator.isSaving)
                }
            }
        }
    }
}
