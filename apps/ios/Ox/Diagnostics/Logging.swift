import Foundation
import os
import Synchronization

nonisolated enum LogContext {
    @TaskLocal static var turnID: UUID?
    @TaskLocal static var conversationID: String?
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

    enum CallKind: String, Sendable {
        case tool, function
    }

    private struct Call: Sendable {
        let kind: CallKind
        let name: String
        let startedMs: Int64
    }

    private struct State: Sendable {
        var events: [Event] = []
        var counts: [Milestone: Int] = [:]
        var inputTokens = 0
        var cachedInputTokens = 0
        var cacheWriteInputTokens = 0
        var cacheWriteSamples = 0
        var outputTokens = 0
        var totalTokens = 0
        var usageSamples = 0
        var missingUsage = 0
        var compactionTurns = 0
        var turnID: UUID?
        var calls: [String: Call] = [:]
        var callCounts: [CallKind: [String: Int]] = [:]
        var callFailures: [CallKind: Int] = [:]
        var callDurations: [CallKind: Int64] = [:]
        var toolIntervals: [ClosedRange<Int64>] = []
        var finished = false
    }

    let submissionID: UUID
    let conversationID: UUID
    let kind: String
    private let clock = ContinuousClock()
    private let startedAt: ContinuousClock.Instant
    private let state = Mutex(State())

    init(submissionID: UUID, conversationID: UUID, kind: String) {
        self.submissionID = submissionID
        self.conversationID = conversationID
        self.kind = kind
        startedAt = clock.now
        mark(.submitted)
    }

    var turnID: UUID? { state.withLock { $0.turnID } }

    func bindTurn(_ turnID: UUID?) {
        state.withLock { state in
            guard !state.finished else { return }
            state.turnID = turnID
        }
    }

    func mark(_ milestone: Milestone) {
        let elapsedMs = Self.milliseconds(startedAt.duration(to: clock.now))
        state.withLock { state in
            guard !state.finished else { return }
            let count = state.counts[milestone, default: 0] + 1
            guard milestone.repeats || count == 1 else { return }
            state.counts[milestone] = count
            let label = milestone.repeats ? "\(milestone.rawValue)[\(count)]" : milestone.rawValue
            state.events.append(Event(milestone: milestone, label: label, elapsedMs: elapsedMs))
        }
    }

    func recordModelStarted(compaction: Bool) {
        state.withLock { state in
            guard !state.finished else { return }
            if compaction { state.compactionTurns += 1 }
        }
        mark(.modelStarted)
    }

    static func hasUsage(_ usage: Usage) -> Bool {
        usage.input > 0 || usage.output > 0 || usage.totalTokens > 0 || usage.cachedInput > 0 || (usage.cacheWriteInput ?? 0) > 0
    }

    static func usageDescription(_ usage: Usage?) -> String {
        guard let usage, hasUsage(usage) else {
            return "usageKnown=false tokens=n/a input=n/a cached=n/a cacheWrite=n/a output=n/a"
        }
        let total = usage.totalTokens > 0 ? usage.totalTokens : usage.input + usage.output
        return "usageKnown=true tokens=\(total) input=\(usage.input) cached=\(usage.cachedInput) cacheWrite=\(usage.cacheWriteInput.map(String.init) ?? "n/a") output=\(usage.output)"
    }

    func recordModelCompleted(_ usage: Usage?) {
        state.withLock { state in
            guard !state.finished else { return }
            guard let usage, Self.hasUsage(usage) else {
                state.missingUsage += 1
                return
            }
            state.usageSamples += 1
            state.inputTokens += usage.input
            state.cachedInputTokens += usage.cachedInput
            if let cacheWriteInput = usage.cacheWriteInput {
                state.cacheWriteInputTokens += cacheWriteInput
                state.cacheWriteSamples += 1
            }
            state.outputTokens += usage.output
            state.totalTokens += usage.totalTokens > 0 ? usage.totalTokens : usage.input + usage.output
        }
        mark(.modelCompleted)
    }

    func recordCallStarted(id: String, name: String, kind: CallKind) {
        let elapsedMs = Self.milliseconds(startedAt.duration(to: clock.now))
        let started = state.withLock { state in
            guard !state.finished, state.calls[id] == nil else { return false }
            state.calls[id] = Call(kind: kind, name: name, startedMs: elapsedMs)
            state.callCounts[kind, default: [:]][name, default: 0] += 1
            return true
        }
        guard started else { return }
        if kind == .tool { mark(.toolStarted) }
        LogContext.$latency.withValue(self) {
            Log.agent.info("AgentCall.start kind=\(kind.rawValue) id=\(id) name=\(name)")
        }
    }

    func recordCallCompleted(id: String, failed: Bool) {
        let elapsedMs = Self.milliseconds(startedAt.duration(to: clock.now))
        let completed = state.withLock { state -> (Call, Int64)? in
            guard !state.finished, let call = state.calls.removeValue(forKey: id) else { return nil }
            let duration = max(0, elapsedMs - call.startedMs)
            state.callDurations[call.kind, default: 0] += duration
            if failed { state.callFailures[call.kind, default: 0] += 1 }
            if call.kind == .tool { state.toolIntervals.append(call.startedMs...max(call.startedMs, elapsedMs)) }
            return (call, duration)
        }
        guard let (call, duration) = completed else { return }
        if call.kind == .tool { mark(.toolCompleted) }
        LogContext.$latency.withValue(self) {
            Log.agent.info("AgentCall.end kind=\(call.kind.rawValue) id=\(id) name=\(call.name) outcome=\(failed ? "failed" : "completed") durationMs=\(duration)")
        }
    }

    private func toolWallMilliseconds(_ intervals: [ClosedRange<Int64>]) -> Int64 {
        var end: Int64 = 0
        var total: Int64 = 0
        for interval in intervals.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            total += max(0, interval.upperBound - max(end, interval.lowerBound))
            end = max(end, interval.upperBound)
        }
        return total
    }

    func finish(outcome: String, client: String, model: String) {
        let now = clock.now
        let totalMs = Self.milliseconds(startedAt.duration(to: now))
        let summary = state.withLock { state -> String? in
            guard !state.finished else { return nil }
            state.finished = true
            let completedCount = state.counts[.completed, default: 0] + 1
            state.counts[.completed] = completedCount
            state.events.append(Event(milestone: .completed, label: Milestone.completed.rawValue, elapsedMs: totalMs))

            func first(_ milestone: Milestone) -> Int64? {
                state.events.first(where: { $0.milestone == milestone })?.elapsedMs
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
            let openToolIntervals = state.calls.values.filter { $0.kind == .tool }.map { min($0.startedMs, totalMs)...totalMs }
            let toolWallMs = toolWallMilliseconds(state.toolIntervals + openToolIntervals)
            func calls(_ kind: CallKind) -> String {
                (state.callCounts[kind] ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
            }
            func tokens(_ count: Int) -> String { state.usageSamples > 0 ? String(count) : "n/a" }
            let usageComplete = state.missingUsage == 0 && state.counts[.modelCompleted, default: 0] == state.counts[.modelStarted, default: 0]
            let timeline = state.events.map { "\($0.label):\($0.elapsedMs)" }.joined(separator: ",")
            let cacheWrite = state.cacheWriteSamples > 0 ? String(state.cacheWriteInputTokens) : "n/a"
            return "AgentLatency.summary conversation=\(conversationID) submission=\(submissionID.uuidString) kind=\(kind) outcome=\(outcome) client=\(client) model=\(model) totalMs=\(totalMs) queueMs=\(value(queueMs)) prepareMs=\(value(prepareMs)) ttftMs=\(value(ttftMs)) firstThinkingMs=\(value(firstThinkingMs)) firstTextMs=\(value(firstTextMs)) firstVisibleMs=\(value(firstVisibleMs)) toolWallMs=\(toolWallMs) modelTurns=\(state.counts[.modelStarted, default: 0]) compactionTurns=\(state.compactionTurns) toolCalls=\(state.counts[.toolStarted, default: 0]) toolFailures=\(state.callFailures[.tool, default: 0]) toolMs=\(state.callDurations[.tool, default: 0]) tools=[\(calls(.tool))] functionCalls=\((state.callCounts[.function] ?? [:]).values.reduce(0, +)) functionFailures=\(state.callFailures[.function, default: 0]) functionMs=\(state.callDurations[.function, default: 0]) functions=[\(calls(.function))] unfinishedCalls=\(state.calls.count) usageSamples=\(state.usageSamples) missingUsage=\(state.missingUsage) usageComplete=\(usageComplete) tokens=\(tokens(state.totalTokens)) input=\(tokens(state.inputTokens)) cached=\(tokens(state.cachedInputTokens)) cacheWrite=\(cacheWrite) output=\(tokens(state.outputTokens)) timeline=\(timeline)"
        }
        if let summary { Log.perf.info(summary) }
    }

    static func milliseconds(_ duration: Duration) -> Int64 {
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
        let context = [
            (LogContext.latency?.conversationID.uuidString ?? LogContext.conversationID).map { "conversation=\($0)" },
            LogContext.latency.map { "submission=\($0.submissionID.uuidString)" },
            (LogContext.turnID ?? LogContext.latency?.turnID).map { "turn=\($0.uuidString)" },
        ].compactMap { $0 }.joined(separator: " ")
        let msg = context.isEmpty ? message : "\(context) \(message)"
        let loc = Self.loc(file, line)
        let thread = Self.currentThread()
        let date = Date()
        switch level {
        case .debug:   oslog.debug("\(loc, privacy: .public) \(msg, privacy: .public)")
        case .info:    oslog.info("\(loc, privacy: .public) \(msg, privacy: .public)")
        case .warning: oslog.warning("\(loc, privacy: .public) \(msg, privacy: .public)")
        case .error:   oslog.error("\(loc, privacy: .public) \(msg, privacy: .public)")
        }
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

nonisolated struct LogEntry: Sendable {
    let id: Int
    let date: Date
    let level: Logger.Level
    let category: String
    let thread: String
    let location: String
    let message: String
}
