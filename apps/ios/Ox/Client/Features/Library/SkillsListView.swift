import SwiftUI

private struct SidebarSafeSkillButton<Label: View>: View {
    let skill: Skill
    let action: () -> Void
    let label: Label

    @Environment(\.sidebarInteraction) private var sidebarInteraction

    init(
        skill: Skill,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.skill = skill
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button {
            guard !sidebarInteraction.dragActive else {
                Log.ui.info("SkillsListView.edit suppressed=sidebarDrag skill=\(skill.name)")
                return
            }
            action()
        } label: {
            label
        }
    }
}

struct SkillsListView: View {
    @Environment(ServiceManager.self) private var serviceManager
    @State private var skills: Skills
    let ready: Bool
    let profileID: UUID

    @Binding private var editing: SkillDraft?
    @State private var pendingDelete: Skill?
    @State private var scheduledSkills = ScheduledSkills.shared
    @State private var query = ""

    init(
        skills: Skills,
        editing: Binding<SkillDraft?>,
        ready: Bool,
        profileID: UUID
    ) {
        _skills = State(initialValue: skills)
        _editing = editing
        self.ready = ready
        self.profileID = profileID
    }

    var body: some View {
        Group {
            if !ready {
                Color.clear
            } else if !skills.isLoaded {
                ContentLoadingView(label: "Loading skills…")
            } else {
                skillList
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(Theme.Colors.background)
        .navigationTitle("Skills")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New Skill", systemImage: "plus") {
                    editing = SkillDraft()
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("New Skill")
                .accessibilityIdentifier(A11yID.Settings.skillCreate)
            }
        }
        .searchable(text: $query, prompt: "Search skills")
        .onChange(of: Skills.shared.repositorySkills) { _, _ in skills.refresh() }
        .alert("Could not update skill", isPresented: Binding(get: { skills.errorMessage != nil }, set: { if !$0 { skills.dismissError() } })) {
            Button("OK") { skills.dismissError() }
        } message: { Text(verbatim: skills.errorMessage ?? "") }
        .navigationDestination(item: $editing) { draft in
            SkillEditorView(draft: draft, skills: skills, profileID: profileID)
                .id(draft.id)
        }
        .alert(
            "Delete /\(pendingDelete?.displayName ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let skill = pendingDelete { skills.delete(skill, manager: serviceManager) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }

    private var skillList: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.sm) {
                ForEach(skills.conflicts) { conflict in
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text(verbatim: "/\(conflict.name)").font(Theme.Fonts.bodyMd)
                        Text("Choose a source").font(Theme.Fonts.caption)
                        ForEach(conflict.candidates) { candidate in
                            Button {
                                skills.select(name: conflict.name, source: candidate.owner.id)
                            } label: {
                                HStack {
                                    Text(verbatim: candidate.owner.name)
                                    Spacer()
                                    if conflict.selectedSourceID == candidate.owner.id { Image(systemName: "checkmark") }
                                }
                            }
                            .accessibilityIdentifier("skill.source.\(conflict.name).\(candidate.owner.id)")
                        }
                        if conflict.candidates.isEmpty { Text("The selected source is unavailable.") }
                    }
                    .padding(.vertical, Theme.Spacing.md)
                }
                let displayed = displayedSkills
                if skills.all.isEmpty {
                    emptyNote
                } else if displayed.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(displayed) { skill in
                        row(skill)
                    }
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .scrollIndicators(.hidden)
    }

    private var emptyNote: some View {
        LibraryEmptyNote(
            destination: .skills,
            title: "No skills yet",
            detail: "Add a skill, then type / in a chat to drop its instructions into the message."
        )
    }

    private var displayedSkills: [Skill] {
        guard !query.isEmpty else { return skills.all }
        return skills.all.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.description.localizedCaseInsensitiveContains(query)
        }
    }

    private var activeSchedules: [ScheduledSkill] {
        scheduledSkills.schedules(profileID: profileID)
    }

    private var scheduledSkillNames: Set<String> {
        Set(activeSchedules.map(\.skill.name))
    }

    private func row(_ skill: Skill) -> some View {
        SidebarSafeSkillButton(skill: skill) {
            editing = SkillDraft(skill)
        } label: {
            SkillLibraryRow(skill: skill, hasSchedules: scheduledSkillNames.contains(skill.name))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(A11yID.Settings.skillRow(skill.name))
        .contextMenuPreviewShape()
        .contextMenu {
            ShareLink(
                item: SkillPackageDocument(skill: skill),
                preview: SharePreview(Text(verbatim: "/\(skill.displayName)"))
            ) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier(A11yID.Settings.skillShare(skill.name))
            if skill.owner.isWritable {
            Button(role: .destructive) {
                pendingDelete = skill
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier(A11yID.Settings.skillDelete(skill.name))
            }
            if skill.owner != .user {
                Button("Customize", systemImage: "doc.on.doc") {
                    skills.customize(skill, name: skill.name + "-copy")
                }
            }
            if skill.owner.id != "repository:local" {
                Button("Add to Local Repository", systemImage: "square.and.arrow.up") { skills.share(skill, manager: serviceManager) }
            }
        } preview: {
            SkillContextMenuPreview(skill: skill)
        }
    }
}

struct SkillLibraryRow: View {
    let skill: Skill
    let hasSchedules: Bool

    init(skill: Skill, hasSchedules: Bool = false) {
        self.skill = skill
        self.hasSchedules = hasSchedules
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "/\(skill.displayName)")
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                Text(verbatim: skill.owner.name).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.onSurfaceMuted)
                Text(verbatim: skill.description)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if hasSchedules {
                Image(systemName: "clock")
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .accessibilityLabel("Scheduled")
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct SkillDraft: Identifiable, Hashable {
    let id = UUID()
    var owner: SkillOwner = .user
    var resources: [String: String]? = nil
    var originalName: String?
    var name: String
    var description: String
    var instructions: String
    var services: [String]

    init() {
        originalName = nil
        name = ""
        description = ""
        instructions = ""
        services = []
    }

    init(_ skill: Skill) {
        owner = skill.owner
        resources = skill.resources
        originalName = skill.name
        name = skill.displayName
        description = skill.description
        instructions = skill.instructions
        services = skill.services
    }
}

struct SkillEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ServiceManager.self) private var serviceManager
    private let skills: Skills
    private let profileID: UUID?

    @State private var name: String
    @State private var description: String
    @State private var instructions: String
    @State private var services: [String]
    @State private var pickingServices = false
    private let owner: SkillOwner
    private let resources: [String: String]?
    private let originalName: String?

    @FocusState private var instructionsFocused: Bool

    init(draft: SkillDraft, skills: Skills, profileID: UUID?) {
        _name = State(initialValue: draft.name)
        _description = State(initialValue: draft.description)
        _instructions = State(initialValue: draft.instructions)
        _services = State(initialValue: draft.services)
        owner = draft.owner
        resources = draft.resources
        originalName = draft.originalName
        self.skills = skills
        self.profileID = profileID
    }

    private var slug: String { SkillFiles.slug(name) }

    private var conflict: Bool {
        SkillFiles.reservedNames.contains(slug) && owner != .system
            || slug != originalName && skills.skill(named: slug)?.owner == owner
    }

    private var canSave: Bool {
        owner.isWritable && !slug.isEmpty
            && !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !conflict
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(spacing: 2) {
                    Text(verbatim: "/")
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    TextField("name", text: $name)
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.onSurface)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier(A11yID.Settings.skillName)
                        .disabled(!owner.isWritable)
                }
                .padding(Theme.Spacing.sm)
                .background(
                    Theme.Colors.surface,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                )

                if conflict {
                    Text("A skill named /\(SkillFiles.displayName(slug)) already exists.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.error)
                        .padding(.horizontal, Theme.Spacing.sm)
                }

                Text("Describe when this skill is useful.")
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .padding(.horizontal, Theme.Spacing.sm)

                TextField("Description", text: $description, axis: .vertical)
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .lineLimit(2...4)
                    .padding(Theme.Spacing.sm)
                    .background(
                        Theme.Colors.surface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    )
                    .accessibilityIdentifier(A11yID.Settings.skillDescription)
                    .disabled(!owner.isWritable)

                Text("These instructions drop into the message box when you pick the skill in a chat.")
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .padding(.horizontal, Theme.Spacing.sm)

                TextEditor(text: $instructions)
                    .focused($instructionsFocused)
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 220, alignment: .topLeading)
                    .padding(.horizontal, 3)
                    .background(
                        Theme.Colors.surface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    )
                    .accessibilityIdentifier(A11yID.Settings.skillInstructions)
                    .disabled(!owner.isWritable)

                serviceSection.disabled(!owner.isWritable)

                if let skill = persistedSkill {
                    SkillSchedulesSection(skill: skill, profileID: profileID)
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .scrollIndicators(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle(originalName == nil ? "New Skill" : "/\(SkillFiles.displayName(originalName ?? ""))")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if owner.isWritable {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier(A11yID.Settings.skillSave)
                } else {
                    Button("Customize") {
                        if let skill = persistedSkill { skills.customize(skill, name: skill.name + "-copy") }
                    }
                }
            }
        }
        .sheet(isPresented: $pickingServices) {
            SkillServicePicker(selected: $services)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.Colors.background)
        }
    }

    private var serviceSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Picking this skill auto-attaches these services to the chat.")
                .font(Theme.Fonts.bodySm)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .padding(.horizontal, Theme.Spacing.sm)

            ChipFlowLayout(spacing: 6) {
                ForEach(services, id: \.self) { domain in
                    servicePill(domain)
                }
                addServiceButton
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 2)
        }
    }

    private var persistedSkill: Skill? {
        guard let originalName else { return nil }
        return skills.skill(named: originalName)
    }

    private func servicePill(_ domain: String) -> some View {
        let service = serviceManager.service(domain: domain)
        let title = service?.title ?? domain
        return ServiceChip(
            service: service,
            title: title,
            onRemove: {
                services.removeAll { $0 == domain }
            },
            removeAccessibilityIdentifier: A11yID.Settings.skillServiceRemove(domain),
            fill: Theme.Colors.chipOnBackground
        )
    }

    private var addServiceButton: some View {
        Button {
            pickingServices = true
        } label: {
            Chip(fill: Theme.Colors.chipOnBackground) {
                Image(systemName: "plus")
                    .font(Theme.Icons.xs)
                Text("Add service")
                    .font(Theme.Fonts.labelMd)
            }
        }
        .foregroundStyle(Theme.Colors.onSurface)
        .buttonStyle(.plain)
        .accessibilityIdentifier(A11yID.Settings.skillAddService)
    }

    private func save() {
        skills.upsert(
            name: name,
            description: description,
            instructions: instructions,
            services: services,
            replacing: originalName,
            resources: resources,
            owner: owner,
            manager: serviceManager
        )
        Task {
            await skills.waitUntilCurrent()
            if skills.errorMessage == nil { dismiss() }
        }
    }
}

private struct SkillServicePicker: View {
    @Binding var selected: [String]
    @Environment(\.dismiss) private var dismiss
    @Environment(ServiceManager.self) private var serviceManager
    @State private var query = ""

    private var matches: [Service] {
        let all = serviceManager.services
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter {
            $0.title.lowercased().contains(needle) || $0.domain.lowercased().contains(needle)
        }
    }

    private var isLoadingServices: Bool {
        serviceManager.monoRepositoryState != .ready
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if isLoadingServices {
                        MonoRepositoryLoadingStatus(
                            accessibilityIdentifier: A11yID.Settings.skillServicesLoading
                        )
                    }
                    ForEach(matches) { service in
                        Button { toggle(service.domain) } label: { row(service) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(A11yID.Settings.skillService(service.domain))
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .background(Theme.Colors.surface)
            .searchable(text: $query)
            .navigationTitle("Services")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ service: Service) -> some View {
        let picked = selected.contains(service.domain)
        return HStack(spacing: Theme.Spacing.md) {
            ServiceAvatar(service: service, size: 34, shape: .roundedRect(Theme.Radius.sm))
            VStack(alignment: .leading, spacing: 2) {
                Text(service.title)
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                Text(service.summary.isEmpty ? service.domain : service.summary)
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if picked {
                Image(systemName: "checkmark")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.Colors.primary)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func toggle(_ domain: String) {
        if let index = selected.firstIndex(of: domain) {
            selected.remove(at: index)
        } else {
            selected.append(domain)
        }
    }
}
