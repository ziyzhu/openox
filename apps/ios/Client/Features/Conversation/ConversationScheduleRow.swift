import SwiftUI

struct ConversationScheduleRow: View {
    let scheduleID: UUID
    let fallbackTitle: String
    let accessibilityIdentifier: String

    @State private var schedules = ScheduledSkills.shared
    @State private var showsDetails = false

    private var schedule: ScheduledSkill? { schedules.schedule(id: scheduleID) }

    var body: some View {
        Button { showsDetails = true } label: {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "clock")
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: schedule?.skill.displayName ?? fallbackTitle)
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.onSurface)
                    Text(verbatim: subtitle)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
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
        .sheet(isPresented: $showsDetails) {
            NavigationStack {
                ConversationScheduleDetails(scheduleID: scheduleID)
            }
            .presentationBackground(Theme.Colors.background)
        }
    }

    private var subtitle: String {
        guard let schedule else { return L10n.string("Schedule unavailable") }
        if !schedule.isEnabled {
            return schedule.nextFireAt == nil ? L10n.string("Finished") : L10n.string("Paused")
        }
        return schedule.recurrence.displaySummary
    }
}

private struct ConversationScheduleDetails: View {
    let scheduleID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var schedules = ScheduledSkills.shared
    @State private var editor: ScheduledSkillEditorTarget?
    @State private var confirmsDelete = false
    @State private var errorMessage: String?
    @State private var isUpdating = false

    private var schedule: ScheduledSkill? { schedules.schedule(id: scheduleID) }

    var body: some View {
        Form {
            if let schedule {
                Section {
                    if !schedule.argument.isEmpty {
                        Text(verbatim: schedule.argument)
                    }
                    LabeledContent("Repeat", value: schedule.recurrence.displaySummary)
                    if let next = schedule.nextFireAt, schedule.isEnabled {
                        LabeledContent("Next run", value: next.formatted(date: .abbreviated, time: .shortened))
                    }
                    if case .failed(let message) = schedule.lastOutcome {
                        Text(verbatim: message)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    }
                }
                Section {
                    Button("Delete schedule", role: .destructive) { confirmsDelete = true }
                        .accessibilityIdentifier("\(identifier).delete")
                }
                .disabled(isUpdating)
                Section {
                    Text("Runs may be delayed while Ox is in the background.")
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                }
            } else {
                Text("Schedule unavailable")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle(schedule?.skill.displayName ?? L10n.string("Schedule"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let schedule {
                    Button("Edit", systemImage: "square.and.pencil") {
                        editor = ScheduledSkillEditorTarget(skill: schedule.skill, profileID: schedule.profileID, schedule: schedule)
                    }
                    .labelStyle(.iconOnly)
                    .environment(\.symbolVariants, .none)
                    .disabled(isUpdating)
                    .accessibilityIdentifier("\(identifier).edit")
                    if schedule.nextFireAt != nil {
                        Button(schedule.isEnabled ? "Pause" : "Resume", systemImage: schedule.isEnabled ? "pause.circle" : "play.circle") {
                            update { try await OxClient.shared.setScheduleEnabled(!schedule.isEnabled, id: scheduleID) }
                        }
                        .labelStyle(.iconOnly)
                        .environment(\.symbolVariants, .none)
                        .disabled(isUpdating)
                        .accessibilityIdentifier("\(identifier).pause")
                    }
                }
            }
        }
        .sheet(item: $editor) { target in
            NavigationStack { ScheduledSkillEditorView(target: target) }
                .presentationBackground(Theme.Colors.background)
        }
        .confirmationDialog("Delete this schedule?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete schedule", role: .destructive) {
                update {
                    try await OxClient.shared.deleteSchedule(scheduleID)
                    dismiss()
                }
            }
            .accessibilityIdentifier("\(identifier).confirmDelete")
        } message: {
            Text("Future runs will stop. Your conversations will be kept.")
        }
        .alert("Couldn't Update Schedule", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
                .accessibilityIdentifier("\(identifier).errorDismiss")
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var identifier: String { A11yID.ConversationControls.Message.schedule(scheduleID.uuidString) }

    private func update(_ operation: @escaping @MainActor () async throws -> Void) {
        isUpdating = true
        Task { @MainActor in
            defer { isUpdating = false }
            do { try await operation() }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

extension ConversationScheduleRow {
    init?(invocation: Invocation) {
        guard invocation.name == Actions.scheduleCreate,
              case .succeeded(let value?) = invocation.outcome,
              let fields = value.objectValue,
              let rawID = fields["id"]?.stringValue,
              let id = UUID(uuidString: rawID) else { return nil }
        scheduleID = id
        fallbackTitle = fields["skill"]?.stringValue ?? invocation.purpose
        accessibilityIdentifier = A11yID.ConversationControls.Message.schedule(rawID)
    }
}
