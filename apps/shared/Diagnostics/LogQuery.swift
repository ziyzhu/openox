import Foundation

nonisolated struct LogQuery {
    let level: Logger.Level
    let category: String?
    let query: String?
    let since: Date?

    init(options: JSONValue?) throws {
        guard let fields = options?.objectValue,
              Set(fields.keys).isSubset(of: ["level", "category", "query", "since"]) else {
            throw RuntimeError.bridge("Expected log filters")
        }
        func string(_ key: String, maximum: Int) throws -> String? {
            guard let value = fields[key] else { return nil }
            guard let text = value.stringValue, !text.isEmpty, text.count <= maximum else {
                throw RuntimeError.bridge("Invalid log filter: \(key)")
            }
            return text
        }
        let levels: [String: Logger.Level] = ["debug": .debug, "info": .info, "warning": .warning, "error": .error]
        guard let level = levels[try string("level", maximum: 7) ?? "debug"] else {
            throw RuntimeError.bridge("Invalid log level")
        }
        self.level = level
        category = try string("category", maximum: 80)
        query = try string("query", maximum: 200)
        if let timestamp = try string("since", maximum: 40) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fractional = formatter.date(from: timestamp)
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = fractional ?? formatter.date(from: timestamp) else {
                throw RuntimeError.bridge("Log since filter must be an ISO 8601 timestamp with a time zone")
            }
            since = date
        } else { since = nil }
    }
}
