import SwiftUI

struct SkillSchedulesSection: View {
    let skill: Skill

    @State private var scheduledSkills = ScheduledSkills.shared
    @State private var editor: ScheduledSkillEditorTarget?
    @State private var pendingDelete: ScheduledSkill?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Schedules")
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.onSurface)
                .padding(.horizontal, Theme.Spacing.sm)

            if schedules.isEmpty {
                Text("Run this skill once or on a repeating schedule.")
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .padding(.horizontal, Theme.Spacing.sm)
            } else {
                ForEach(schedules) { schedule in
                    scheduleRow(schedule)
                }
            }

            Button {
                editor = ScheduledSkillEditorTarget(skill: skill)
            } label: {
                Chip(fill: Theme.Colors.chipOnBackground) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Add schedule")
                        .font(Theme.Fonts.labelMd)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.onSurface)
            .minimumTouchTarget(alignment: .leading)
            .accessibilityIdentifier(A11yID.Settings.skillSchedule(skill.name))
        }
        .sheet(item: $editor) { target in
            NavigationStack {
                ScheduledSkillEditorView(target: target)
            }
            .presentationBackground(Theme.Colors.background)
        }
        .alert(
            "Delete this schedule?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let schedule = pendingDelete {
                    do {
                        try scheduledSkills.delete(id: schedule.id)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
        .alert("Couldn't Update Schedule", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var schedules: [ScheduledSkill] {
        scheduledSkills.schedules(profileID: StorageRoot.shared.activeId).filter {
            $0.skill.name == skill.name
        }
    }

    private func scheduleRow(_ schedule: ScheduledSkill) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Button {
                editor = ScheduledSkillEditorTarget(skill: schedule.skill, schedule: schedule)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(schedule.recurrence.displaySummary)
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.onSurface)
                    if !schedule.isEnabled {
                        Text("Paused")
                            .font(Theme.Fonts.captionSm)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    } else if schedule.recurrence.isRepeating,
                              let next = schedule.nextFireAt {
                        Text("Next \(next.formatted(date: .abbreviated, time: .shortened))")
                            .font(Theme.Fonts.captionSm)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(A11yID.Settings.scheduleRow(schedule.id.uuidString))

            Toggle("Enabled", isOn: scheduleEnabledBinding(schedule))
                .labelsHidden()
                .tint(Theme.Colors.primary)
                .accessibilityIdentifier(A11yID.Settings.scheduleEnabled(schedule.id.uuidString))
        }
        .padding(Theme.Spacing.sm)
        .background(
            Theme.Colors.surface,
            in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
        )
        .contextMenu {
            Button {
                ScheduledSkillScheduler.shared.runNow(id: schedule.id)
            } label: {
                Label("Run Now", systemImage: "play")
            }
            Button {
                editor = ScheduledSkillEditorTarget(skill: schedule.skill, schedule: schedule)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive) {
                pendingDelete = schedule
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func scheduleEnabledBinding(_ schedule: ScheduledSkill) -> Binding<Bool> {
        Binding(
            get: { scheduledSkills.schedule(id: schedule.id)?.isEnabled ?? false },
            set: { enabled in
                do {
                    try scheduledSkills.setEnabled(enabled, id: schedule.id)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        )
    }
}

struct ScheduledSkillEditorTarget: Identifiable {
    let id = UUID()
    let skill: Skill
    let schedule: ScheduledSkill?

    init(skill: Skill, schedule: ScheduledSkill? = nil) {
        self.skill = skill
        self.schedule = schedule
    }
}

private enum ScheduledSkillEditorFrequency: String, CaseIterable, Identifiable {
    case once = "Once"
    case daily = "Daily"
    case weekly = "Weekly"

    var id: Self { self }
}

struct ScheduledSkillEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var frequency: ScheduledSkillEditorFrequency
    @State private var date: Date
    @State private var weekday: Int
    @State private var errorMessage: String?

    private let target: ScheduledSkillEditorTarget
    private let timeZone = TimeZone.autoupdatingCurrent.identifier

    init(target: ScheduledSkillEditorTarget) {
        self.target = target
        let initial = Self.initialValues(target.schedule)
        _frequency = State(initialValue: initial.frequency)
        _date = State(initialValue: initial.date)
        _weekday = State(initialValue: initial.weekday)
    }

    var body: some View {
        Form {
            Section {
                Picker("Repeat", selection: $frequency) {
                    ForEach(ScheduledSkillEditorFrequency.allCases) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
                switch frequency {
                case .once:
                    DatePicker("Run At", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                case .daily:
                    DatePicker("Run At", selection: $date, displayedComponents: .hourAndMinute)
                case .weekly:
                    Picker("Day", selection: $weekday) {
                        ForEach(Array(Calendar.autoupdatingCurrent.weekdaySymbols.enumerated()), id: \.offset) { index, name in
                            Text(name).tag(index + 1)
                        }
                    }
                    DatePicker("Run At", selection: $date, displayedComponents: .hourAndMinute)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle(target.schedule == nil ? "Schedule Skill" : "Edit Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }
                    .accessibilityIdentifier(A11yID.Settings.scheduleSave)
            }
        }
        .alert("Couldn't Save Schedule", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var recurrence: ScheduledSkillRecurrence {
        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
        let hour = components.hour ?? 9
        let minute = components.minute ?? 0
        return switch frequency {
        case .once: .once(date)
        case .daily: .daily(hour: hour, minute: minute, timeZone: timeZone)
        case .weekly: .weekly(weekday: weekday, hour: hour, minute: minute, timeZone: timeZone)
        }
    }

    private func save() {
        do {
            if let schedule = target.schedule {
                try ScheduledSkills.shared.update(
                    id: schedule.id,
                    skill: schedule.skill,
                    argument: schedule.argument,
                    recurrence: recurrence
                )
            } else {
                try ScheduledSkills.shared.create(
                    skill: target.skill,
                    argument: "",
                    recurrence: recurrence,
                    profileID: StorageRoot.shared.activeId
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func initialValues(
        _ schedule: ScheduledSkill?
    ) -> (frequency: ScheduledSkillEditorFrequency, date: Date, weekday: Int) {
        guard let recurrence = schedule?.recurrence else {
            let date = Calendar.autoupdatingCurrent.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
            let weekday = Calendar.autoupdatingCurrent.component(.weekday, from: date)
            return (.once, date, weekday)
        }
        switch recurrence {
        case .once(let date):
            return (.once, max(date, Date()), Calendar.autoupdatingCurrent.component(.weekday, from: date))
        case let .daily(hour, minute, _):
            return (.daily, time(hour: hour, minute: minute), Calendar.autoupdatingCurrent.component(.weekday, from: Date()))
        case let .weekly(weekday, hour, minute, _):
            return (.weekly, time(hour: hour, minute: minute), weekday)
        }
    }

    private static func time(hour: Int, minute: Int) -> Date {
        Calendar.autoupdatingCurrent.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }
}

nonisolated extension ScheduledSkillRecurrence {
    var displaySummary: String {
        switch self {
        case .once(let date):
            "Runs \(date.formatted(date: .abbreviated, time: .shortened))"
        case let .daily(hour, minute, _):
            "Daily at \(Self.time(hour: hour, minute: minute))"
        case let .weekly(weekday, hour, minute, _):
            "\(Calendar.autoupdatingCurrent.weekdaySymbols[weekday - 1]) at \(Self.time(hour: hour, minute: minute))"
        }
    }

    var isRepeating: Bool {
        switch self {
        case .once: false
        case .daily, .weekly: true
        }
    }

    static func time(hour: Int, minute: Int) -> String {
        let date = Calendar.autoupdatingCurrent.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}
