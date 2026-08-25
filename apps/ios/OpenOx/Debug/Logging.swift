import Foundation
import os
import Synchronization

nonisolated enum LogContext {
    @TaskLocal static var turnID: UUID?
    @TaskLocal static var latency: TurnLatencyTrace?
}

nonisolated final class TurnLatencyTrace: @unchecked Sendable {
    enum Milestone: String, Sendable {
        case submitted
        case posted
        case consumed
        case runStarted
        case agentConfigured
        case manifestsStarted
        case manifestsReady
        case promptReady
        case agentSubmitted
        case agentStarted
        case modelStarted
        case requestBodyReady
        case authReady
        case httpStarted
        case responseHeaders
        case firstToken
        case firstThinkingReceived
        case firstTextReceived
        case firstTextVisible
        case toolStarted
        case toolCompleted
        case modelCompleted
        case agentCompleted
        case completed

        var repeats: Bool {
            switch self {
            case .modelStarted, .requestBodyReady, .authReady, .httpStarted,
                 .responseHeaders, .firstToken, .firstThinkingReceived,
                 .firstTextReceived, .toolStarted, .toolCompleted, .modelCompleted:
                true
            case .submitted, .posted, .consumed, .runStarted, .agentConfigured,
                 .manifestsStarted, .manifestsReady, .promptReady, .agentSubmitted,
                 .agentStarted, .firstTextVisible, .agentCompleted, .completed:
                false
            }
        }
    }

    private struct Event: Sendable {
        let milestone: Milestone
        let label: String
        let elapsedMs: Int64
    }

    private struct State: Sendable {
        var events: [Event] = []
        var counts: [Milestone: Int] = [:]
        var inputTokens = 0
        var cachedInputTokens = 0
        var cacheWriteInputTokens = 0
        var cacheWriteSamples = 0
        var outputTokens = 0
        var finished = false
    }

    let submissionID: UUID
    let kind: String
    private let clock = ContinuousClock()
    private let startedAt: ContinuousClock.Instant
    private let state = Mutex(State())

    init(submissionID: UUID, kind: String) {
        self.submissionID = submissionID
        self.kind = kind
        startedAt = clock.now
        mark(.submitted)
    }

    func mark(_ milestone: Milestone) {
        let elapsedMs = milliseconds(startedAt.duration(to: clock.now))
        state.withLock { state in
            guard !state.finished else { return }
            let count = state.counts[milestone, default: 0] + 1
            guard milestone.repeats || count == 1 else { return }
            state.counts[milestone] = count
            let label = milestone.repeats ? "\(milestone.rawValue)[\(count)]" : milestone.rawValue
            state.events.append(Event(milestone: milestone, label: label, elapsedMs: elapsedMs))
        }
    }

    func recordModelCompleted(_ usage: Usage) {
        state.withLock { state in
            guard !state.finished else { return }
            state.inputTokens += usage.input
            state.cachedInputTokens += usage.cachedInput
            if let cacheWriteInput = usage.cacheWriteInput {
                state.cacheWriteInputTokens += cacheWriteInput
                state.cacheWriteSamples += 1
            }
            state.outputTokens += usage.output
        }
        mark(.modelCompleted)
    }

    func finish(outcome: String, client: String, model: String) {
        let now = clock.now
        let totalMs = milliseconds(startedAt.duration(to: now))
        let summary = state.withLock { state -> String? in
            guard !state.finished else { return nil }
            state.finished = true
            let completedCount = state.counts[.completed, default: 0] + 1
            state.counts[.completed] = completedCount
            state.events.append(Event(milestone: .completed, label: Milestone.completed.rawValue, elapsedMs: totalMs))

            func first(_ milestone: Milestone) -> Int64? {
                state.events.first(where: { $0.milestone == milestone })?.elapsedMs
            }

            func last(_ milestone: Milestone) -> Int64? {
                state.events.last(where: { $0.milestone == milestone })?.elapsedMs
            }

            func delta(_ start: Milestone, _ end: Milestone) -> Int64? {
                guard let startMs = first(start), let endMs = first(end) else { return nil }
                return max(0, endMs - startMs)
            }

            let queueMs = delta(.submitted, .consumed)
            let prepareMs = delta(.consumed, .modelStarted)
            let ttftMs = delta(.modelStarted, .firstToken)
            let firstThinkingMs = first(.firstThinkingReceived)
            let firstTextMs = first(.firstTextReceived)
            let firstVisibleMs = first(.firstTextVisible)
            let toolWallMs: Int64? = if let startMs = first(.toolStarted), let endMs = last(.toolCompleted) {
                max(0, endMs - startMs)
            } else {
                nil
            }
            let timeline = state.events.map { "\($0.label):\($0.elapsedMs)" }.joined(separator: ",")
            let cacheWrite = state.cacheWriteSamples > 0 ? String(state.cacheWriteInputTokens) : "n/a"
            return "AgentLatency.summary submission=\(submissionID.uuidString) kind=\(kind) outcome=\(outcome) client=\(client) model=\(model) totalMs=\(totalMs) queueMs=\(value(queueMs)) prepareMs=\(value(prepareMs)) ttftMs=\(value(ttftMs)) firstThinkingMs=\(value(firstThinkingMs)) firstTextMs=\(value(firstTextMs)) firstVisibleMs=\(value(firstVisibleMs)) toolWallMs=\(value(toolWallMs)) modelTurns=\(state.counts[.modelStarted, default: 0]) toolCalls=\(state.counts[.toolStarted, default: 0]) input=\(state.inputTokens) cached=\(state.cachedInputTokens) cacheWrite=\(cacheWrite) output=\(state.outputTokens) timeline=\(timeline)"
        }
        if let summary { Log.perf.info(summary) }
    }

    private func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
    }

    private func value(_ milliseconds: Int64?) -> String {
        milliseconds.map(String.init) ?? "n/a"
    }
}

nonisolated final class Logger: @unchecked Sendable {
    enum Level: Int, Comparable {
        case debug = 0, info, warning, error
        static func < (l: Level, r: Level) -> Bool { l.rawValue < r.rawValue }

        var name: String {
            switch self {
            case .debug:   return "debug"
            case .info:    return "info"
            case .warning: return "warning"
            case .error:   return "error"
            }
        }
    }

    static let shared = Logger(category: "App")

    #if DEBUG
    var minLevel: Level = .debug
    #else
    var minLevel: Level = .info
    #endif
    var isEnabled: Bool = true

    let category: String
    private let oslog: os.Logger

    init(category: String) {
        let subsystem = Bundle.main.bundleIdentifier ?? "ai.openox"
        self.category = category
        self.oslog = os.Logger(subsystem: subsystem, category: category)
    }

    func debug(_ msg: @autoclosure () -> String, file: String = #fileID, line: Int = #line)   { emit(.debug, msg, file, line) }
    func info(_ msg: @autoclosure () -> String, file: String = #fileID, line: Int = #line)    { emit(.info, msg, file, line) }
    func warning(_ msg: @autoclosure () -> String, file: String = #fileID, line: Int = #line) { emit(.warning, msg, file, line) }
    func error(_ msg: @autoclosure () -> String, file: String = #fileID, line: Int = #line)   { emit(.error, msg, file, line) }

    private func emit(_ level: Level, _ msg: () -> String, _ file: String, _ line: Int) {
        guard isEnabled, level >= minLevel else { return }
        let message = msg()
        let msg = LogContext.turnID.map { "turn=\($0.uuidString) \(message)" } ?? message
        let loc = Self.loc(file, line)
        let thread = Self.currentThread()
        let date = Date()
        switch level {
        case .debug:   oslog.debug("\(loc, privacy: .public) \(msg, privacy: .public)")
        case .info:    oslog.info("\(loc, privacy: .public) \(msg, privacy: .public)")
        case .warning: oslog.warning("\(loc, privacy: .public) \(msg, privacy: .public)")
        case .error:   oslog.error("\(loc, privacy: .public) \(msg, privacy: .public)")
        }
        LogStore.shared.append(date: date, level: level, category: category, thread: thread, location: loc, message: msg)
        LogFile.shared.append(date: date, level: level, category: category, thread: thread, location: loc, message: msg)
    }

    private static func loc(_ file: String, _ line: Int) -> String {
        let f = (file as NSString).lastPathComponent
        return "[\(f):\(line)]"
    }

    private static func currentThread() -> String {
        if Thread.isMainThread { return "main" }
        if let name = Thread.current.name, !name.isEmpty { return name }
        var tid: UInt64 = 0
        pthread_threadid_np(nil, &tid)
        return "t\(tid)"
    }
}

nonisolated enum Log {
    static let app      = Logger.shared
    static let ui       = Logger(category: "UI")
    static let agent    = Logger(category: "Agent")
    static let network  = Logger(category: "Network")
    static let service  = Logger(category: "Service")
    static let webView  = Logger(category: "WebView")
    static let webSearch = Logger(category: "WebSearch")
    static let webFetch = Logger(category: "WebFetch")
    static let session  = Logger(category: "Session")
    static let perf     = Logger(category: "Perf")
}

nonisolated struct LogEntry: Identifiable, Sendable {
    let id: Int
    let date: Date
    let level: Logger.Level
    let category: String
    let thread: String
    let location: String
    let message: String

    var line: String {
        "\(LogStore.timeFormatter.string(from: date)) \(level.name.uppercased()) [\(category)] (\(thread)) \(location) \(message)"
    }
}

nonisolated final class LogStore: @unchecked Sendable {
    static let shared = LogStore()

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private let maxEntries = 2000
    private struct State {
        var entries: [LogEntry] = []
        var sequence = 0
    }
    private let state = Mutex(State())

    var count: Int {
        state.withLock { $0.entries.count }
    }

    func append(date: Date, level: Logger.Level, category: String, thread: String, location: String, message: String) {
        state.withLock { state in
            state.sequence += 1
            state.entries.append(LogEntry(id: state.sequence, date: date, level: level, category: category, thread: thread, location: location, message: message))
            if state.entries.count > maxEntries + 256 {
                state.entries.removeFirst(state.entries.count - maxEntries)
            }
        }
    }

    func snapshot() -> [LogEntry] {
        state.withLock { $0.entries }
    }

    func clear() {
        state.withLock { $0.entries.removeAll(keepingCapacity: true) }
    }
}
