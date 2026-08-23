import Foundation

struct HealthReadRequest {
    let action: String
    let actionName: String
    let start: Date
    let end: Date
    let args: JSONValue
    let privateDataRequest: PrivateDataRequest

    init(
        start: String?,
        end: String?,
        purpose: String?,
        action: String,
        actionName: String
    ) throws {
        guard let startText = start?.trimmingCharacters(in: .whitespacesAndNewlines),
              let startDate = ISODate.parse(startText) else {
            throw RuntimeError.bridge("\(actionName): 'start' is required and must be an ISO-8601 timestamp.")
        }
        guard let endText = end?.trimmingCharacters(in: .whitespacesAndNewlines),
              let endDate = ISODate.parse(endText) else {
            throw RuntimeError.bridge("\(actionName): 'end' is required and must be an ISO-8601 timestamp.")
        }
        guard endDate > startDate else {
            throw RuntimeError.bridge("\(actionName): 'end' must be later than 'start'.")
        }
        let calendar = Calendar.autoupdatingCurrent
        let firstDay = calendar.startOfDay(for: startDate)
        guard let maximumEnd = calendar.date(byAdding: .day, value: 31, to: firstDay), endDate <= maximumEnd else {
            throw RuntimeError.bridge("\(actionName): the requested range may span at most 31 calendar days.")
        }
        self.action = action
        self.actionName = actionName
        self.start = startDate
        self.end = endDate
        self.args = .object(["start": .string(startText), "end": .string(endText)])
        self.privateDataRequest = PrivateDataRequest(
            actionName: actionName,
            sourceName: L10n.string("Apple Health"),
            storageName: L10n.string("Health data"),
            dataName: Self.dataName(action),
            range: Self.dateRange(start: startDate, end: endDate),
            purpose: purpose
        )
    }

    private static func dataName(_ action: String) -> String {
        switch action {
        case "health.activity": L10n.string("activity data")
        case "health.body.summary": L10n.string("body measurements")
        case "health.sleep.summary": L10n.string("sleep data")
        case "health.vitals.summary": L10n.string("vital signs")
        case "health.workouts.list": L10n.string("workout data")
        default: L10n.string("health data")
        }
    }

    private static func dateRange(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLocale.shared.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let timeZone = formatter.timeZone.abbreviation(for: start) ?? formatter.timeZone.identifier
        return "\(formatter.string(from: start))–\(formatter.string(from: end)) \(timeZone)"
    }
}
