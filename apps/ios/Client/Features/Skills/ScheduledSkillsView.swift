import SwiftUI

struct ScheduledSkillEditorTarget: Identifiable {
    let id = UUID()
    let skill: Skill
    let profileID: UUID?
    let schedule: ScheduledSkill?

    init(skill: Skill, profileID: UUID?, schedule: ScheduledSkill? = nil) {
        self.skill = skill
        self.profileID = profileID
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
    @Environment(ServiceManager.self) private var serviceManager
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
            if let message = dependencyError {
                Section {
                    Text(verbatim: message)
                    NavigationLink("Repositories") { RepositoriesView() }
                }
            }
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

    private var dependencyError: String? {
        do {
            try serviceManager.requireServices(domains: target.skill.services)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func save() {
        do {
            try serviceManager.requireServices(domains: target.skill.services)
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
                    profileID: target.profileID
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
