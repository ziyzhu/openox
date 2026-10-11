import EventKit
import Foundation

@MainActor
final class CalendarProvider {
    static let shared = CalendarProvider()

    struct SavedEvent: Encodable {
        let id: String
        let title: String
        let start: String
        let end: String
    }

    struct SavedReminder: Encodable {
        let id: String
        let title: String
        let due: String?
    }

    enum CalendarError: LocalizedError {
        case eventsDenied
        case remindersDenied
        case noEventCalendar
        case noReminderList
        case noStart
        case badDate(String)
        var errorDescription: String? {
            switch self {
            case .eventsDenied:
                return "Calendar access is off for Ox. Ask the user to enable it in Settings › Privacy & Security › Calendars › Ox, then try again."
            case .remindersDenied:
                return "Reminders access is off for Ox. Ask the user to enable it in Settings › Privacy & Security › Reminders › Ox, then try again."
            case .noEventCalendar:
                return "The user has no default calendar to add events to."
            case .noReminderList:
                return "The user has no default list to add reminders to."
            case .noStart:
                return "'start' is required and must be an ISO-8601 timestamp, e.g. 2026-06-25T09:00:00Z."
            case .badDate(let field):
                return "'\(field)' must be an ISO-8601 timestamp, e.g. 2026-06-25T09:00:00Z."
            }
        }
    }

    private let store = EKEventStore()
    private init() {}

    func addEvent(title: String, start: String?, end: String?, location: String?, notes: String?) async throws -> SavedEvent {
        guard let start = start?.trimmingCharacters(in: .whitespacesAndNewlines), !start.isEmpty else {
            throw CalendarError.noStart
        }
        guard let startDate = ISODate.parse(start) else { throw CalendarError.badDate("start") }
        let endDate: Date
        if let end = end?.trimmingCharacters(in: .whitespacesAndNewlines), !end.isEmpty {
            guard let parsed = ISODate.parse(end) else { throw CalendarError.badDate("end") }
            endDate = parsed
        } else {
            endDate = startDate.addingTimeInterval(3600)
        }

        try await ensureEventsAccess()
        guard let calendar = store.defaultCalendarForNewEvents else { throw CalendarError.noEventCalendar }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        if let location = location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
            event.location = location
        }
        if let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            event.notes = notes
        }
        event.calendar = calendar
        try store.save(event, span: .thisEvent)
        Log.agent.info("calendar.event id=\(event.eventIdentifier ?? "?") start=\(ISODate.string(from: startDate))")
        return SavedEvent(id: event.eventIdentifier ?? "", title: title, start: ISODate.string(from: startDate), end: ISODate.string(from: endDate))
    }

    func addReminder(title: String, due: String?, notes: String?) async throws -> SavedReminder {
        var dueDate: Date?
        if let due = due?.trimmingCharacters(in: .whitespacesAndNewlines), !due.isEmpty {
            guard let parsed = ISODate.parse(due) else { throw CalendarError.badDate("due") }
            dueDate = parsed
        }

        try await ensureRemindersAccess()
        guard let calendar = store.defaultCalendarForNewReminders() else { throw CalendarError.noReminderList }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        if let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            reminder.notes = notes
        }
        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
            reminder.addAlarm(EKAlarm(absoluteDate: dueDate))
        }
        reminder.calendar = calendar
        try store.save(reminder, commit: true)
        Log.agent.info("calendar.reminder id=\(reminder.calendarItemIdentifier) due=\(dueDate.map(ISODate.string(from:)) ?? "none")")
        return SavedReminder(id: reminder.calendarItemIdentifier, title: title, due: dueDate.map(ISODate.string(from:)))
    }

    func requestEventsAccess() async {
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            _ = try? await store.requestWriteOnlyAccessToEvents()
        }
    }

    func requestRemindersAccess() async {
        if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
            _ = try? await store.requestFullAccessToReminders()
        }
    }

    private func ensureEventsAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .writeOnly:
            return
        case .denied, .restricted:
            Log.agent.info("calendar.events.auth denied")
            throw CalendarError.eventsDenied
        case .notDetermined:
            Log.agent.info("calendar.events.auth requesting")
            let granted = (try? await store.requestWriteOnlyAccessToEvents()) ?? false
            if !granted { throw CalendarError.eventsDenied }
        @unknown default:
            throw CalendarError.eventsDenied
        }
    }

    private func ensureRemindersAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return
        case .denied, .restricted, .writeOnly:
            Log.agent.info("calendar.reminders.auth denied")
            throw CalendarError.remindersDenied
        case .notDetermined:
            Log.agent.info("calendar.reminders.auth requesting")
            let granted = (try? await store.requestFullAccessToReminders()) ?? false
            if !granted { throw CalendarError.remindersDenied }
        @unknown default:
            throw CalendarError.remindersDenied
        }
    }
}
