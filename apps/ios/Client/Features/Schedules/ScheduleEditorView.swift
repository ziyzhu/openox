import SwiftUI

struct ScheduleEditorTarget: Identifiable {
    let schedule: Schedule
    var id: UUID { schedule.id }
}

private enum ScheduleEditorFrequency: String, CaseIterable, Identifiable {
    case once = "Once"
    case interval = "Interval"
    case daily = "Daily"
    case weekly = "Weekly"

    var id: Self { self }
}

struct ScheduleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var prompt: String
    @State private var condition: String
    @State private var hasDeadline: Bool
    @State private var deadline: Date
    @State private var intervalSeconds: Int
    @State private var saving = false
    @State private var frequency: ScheduleEditorFrequency
    @State private var date: Date
    @State private var weekday: Int
    @State private var errorMessage: String?

    private let target: ScheduleEditorTarget
    private let timeZone: String

    init(target: ScheduleEditorTarget) {
        self.target = target
        timeZone = target.schedule.recurrence.timeZoneIdentifier
        _name = State(initialValue: target.schedule.name)
        _prompt = State(initialValue: target.schedule.prompt)
        _condition = State(initialValue: target.schedule.condition ?? "")
        _hasDeadline = State(initialValue: target.schedule.deadline != nil)
        _deadline = State(initialValue: target.schedule.deadline ?? Date().addingTimeInterval(86400))
        if case .interval(let seconds) = target.schedule.recurrence { _intervalSeconds = State(initialValue: seconds) }
        else { _intervalSeconds = State(initialValue: 30) }
        let initial = Self.initialValues(target.schedule)
        _frequency = State(initialValue: initial.frequency)
        _date = State(initialValue: initial.date)
        _weekday = State(initialValue: initial.weekday)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("schedule.editor.name")
                TextField("Prompt", text: $prompt, axis: .vertical)
                    .lineLimit(3...8)
                    .accessibilityIdentifier("schedule.editor.prompt")
            }
            Section {
                Picker("Repeat", selection: $frequency) {
                    ForEach(ScheduleEditorFrequency.allCases) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
                .accessibilityIdentifier("schedule.editor.frequency")
                switch frequency {
                case .interval:
                    HStack {
                        Text("Every (seconds)")
                        TextField("Seconds", value: $intervalSeconds, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("schedule.editor.interval")
                    }
                case .once:
                    DatePicker("Run At", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .accessibilityIdentifier("schedule.editor.runAt")
                case .daily:
                    DatePicker("Run At", selection: $date, displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier("schedule.editor.runAt")
                case .weekly:
                    Picker("Day", selection: $weekday) {
                        ForEach(Array(Calendar.autoupdatingCurrent.weekdaySymbols.enumerated()), id: \.offset) { index, name in
                            Text(name).tag(index + 1)
                        }
                    }
                    DatePicker("Run At", selection: $date, displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier("schedule.editor.runAt")
                }
            }
            Section {
                TextField("Stop when (optional)", text: $condition, axis: .vertical)
                    .accessibilityIdentifier("schedule.editor.condition")
                Toggle("Deadline", isOn: $hasDeadline)
                    .accessibilityIdentifier("schedule.editor.hasDeadline")
                if hasDeadline {
                    DatePicker("Stop after", selection: $deadline, in: Date()...)
                        .accessibilityIdentifier("schedule.editor.deadline")
                }
                if !condition.isEmpty {
                    Text("Each run checks this condition. A repeating schedule and deadline are required.")
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                }
            }
        }
        .disabled(saving)
        .scrollContentBackground(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle(target.schedule.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("schedule.editor.cancel")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }
                    .disabled(saving)
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

    private var recurrence: ScheduleRecurrence {
        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
        let hour = components.hour ?? 9
        let minute = components.minute ?? 0
        return switch frequency {
        case .interval: .interval(seconds: intervalSeconds)
        case .once: .once(date)
        case .daily: .daily(hour: hour, minute: minute, timeZone: timeZone)
        case .weekly: .weekly(weekday: weekday, hour: hour, minute: minute, timeZone: timeZone)
        }
    }

    private func save() {
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                guard target.schedule.profileID == StorageRoot.shared.activeId else { throw CancellationError() }
                try await OxClient.shared.updateSchedule(
                    id: target.schedule.id, name: name, prompt: prompt,
                    condition: condition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : condition,
                    deadline: hasDeadline ? deadline : nil, recurrence: recurrence
                )
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private static func initialValues(
        _ schedule: Schedule
    ) -> (frequency: ScheduleEditorFrequency, date: Date, weekday: Int) {
        let recurrence = schedule.recurrence
        switch recurrence {
        case .interval:
            return (.interval, Date(), 1)
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

nonisolated extension ScheduleRecurrence {
    var displaySummary: String {
        switch self {
        case .interval(let seconds):
            "Every \(seconds) seconds"
        case .once(let date):
            "Runs \(date.formatted(date: .abbreviated, time: .shortened))"
        case let .daily(hour, minute, _):
            "Daily at \(Self.time(hour: hour, minute: minute))"
        case let .weekly(weekday, hour, minute, _):
            "\(Calendar.autoupdatingCurrent.weekdaySymbols[weekday - 1]) at \(Self.time(hour: hour, minute: minute))"
        }
    }

    static func time(hour: Int, minute: Int) -> String {
        let date = Calendar.autoupdatingCurrent.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}
