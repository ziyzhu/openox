import Foundation
import CryptoKit
import os
import UIKit

nonisolated final class LogFile: @unchecked Sendable {
    static let shared = LogFile()

    private static let maxBytes: UInt64 = 10 * 1024 * 1024
    private static let compactBytes = 5 * 1024 * 1024
    private static let flushThreshold = 64
    private static let flushDelay: TimeInterval = 2

    private static let directory = AppStoragePaths.applicationSupport
    static let fileURL = AppStoragePaths.logs

    private let queue = DispatchQueue(label: "ai.openox.logfile", qos: .utility)
    private let oslog = os.Logger(subsystem: Bundle.main.bundleIdentifier ?? "ai.openox", category: "LogFile")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private var pending: [Data] = []
    private var flushScheduled = false
    private var handle: FileHandle?

    private init() {
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.flush() }
            }
        }
    }

    private struct Line: Codable {
        let ts: String
        let level: String
        let category: String
        let thread: String
        let loc: String
        let msg: String
    }

    func append(date: Date, level: Logger.Level, category: String, thread: String, location: String, message: String) {
        queue.async {
            let line = Line(ts: self.timestamp.string(from: date), level: level.name, category: category, thread: thread, loc: location, msg: message)
            guard let data = try? self.encoder.encode(line) else { return }
            self.pending.append(data)
            if self.pending.count >= Self.flushThreshold {
                self.flush()
            } else if !self.flushScheduled {
                self.flushScheduled = true
                self.queue.asyncAfter(deadline: .now() + Self.flushDelay) {
                    self.flushScheduled = false
                    self.flush()
                }
            }
        }
    }

    struct Page: Sendable {
        let entries: [LogEntry]
        let nextCursor: String?
    }

    private struct Filters: Encodable {
        let level: String
        let category: String?
        let query: String?
        let since: Date?
    }

    private struct Cursor: Codable {
        let version: Int
        let file: String
        let before: Int
        let anchor: String
        let filters: String
    }

    enum ReadError: LocalizedError {
        case invalidCursor
        case expiredCursor
        case invalidLimit

        var errorDescription: String? {
            switch self {
            case .invalidCursor: "Invalid log cursor or changed filters. Start a new log read."
            case .expiredCursor: "Log cursor expired after compaction or file replacement. Start a new log read."
            case .invalidLimit: "Log page limit must be an integer from 1 to 2000."
            }
        }
    }

    func snapshot() async throws -> [LogEntry] {
        try await read { data in
            data.split(separator: 0x0A).compactMap { self.entry($0) }
        }
    }

    // Pages walk backward; each page retains the existing chronological wire order.
    func page(limit: Int = 2_000, cursor: String? = nil, level: Logger.Level = .debug,
              category: String? = nil, query: String? = nil, since: Date? = nil) async throws -> Page {
        try await read { data in
            guard (1...2_000).contains(limit) else { throw ReadError.invalidLimit }
            if data.isEmpty {
                guard cursor == nil else { throw ReadError.expiredCursor }
                return Page(entries: [], nextCursor: nil)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: Self.fileURL.path)
            guard let file = (attributes[.systemFileNumber] as? NSNumber)?.stringValue else {
                throw CocoaError(.fileReadUnknown)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let filters = Self.digest(try encoder.encode(Filters(level: level.name, category: category, query: query, since: since)))
            var before = data.count
            if let cursor {
                guard cursor.count <= 2_048, let encoded = Data(base64Encoded: cursor),
                      let token = try? self.decoder.decode(Cursor.self, from: encoded),
                      token.version == 1, token.filters == filters else { throw ReadError.invalidCursor }
                guard token.file == file, token.before >= 0, token.before < data.count,
                      token.before == 0 || data[token.before - 1] == 0x0A,
                      token.anchor == Self.digest(Data(data[token.before...].prefix(while: { $0 != 0x0A }))) else {
                    throw ReadError.expiredCursor
                }
                before = token.before
            }
            var entries: [LogEntry] = []
            var hasMore = false
            for line in data[..<before].split(separator: 0x0A).reversed() {
                guard let entry = self.entry(line), entry.level >= level,
                      category == nil || category == entry.category,
                      since.map({ entry.date >= $0 }) ?? true,
                      query.map({ entry.message.localizedCaseInsensitiveContains($0) || entry.category.localizedCaseInsensitiveContains($0) }) ?? true else { continue }
                if entries.count == limit {
                    hasMore = true
                    break
                }
                entries.append(entry)
            }
            var nextCursor: String?
            if hasMore, let oldest = entries.last {
                let offset = oldest.id - 1
                let token = Cursor(version: 1, file: file, before: offset,
                                   anchor: Self.digest(Data(data[offset...].prefix(while: { $0 != 0x0A }))), filters: filters)
                nextCursor = try encoder.encode(token).base64EncodedString()
            }
            return Page(entries: entries.reversed(), nextCursor: nextCursor)
        }
    }

    private static func digest(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }

    private func entry(_ data: Data) -> LogEntry? {
        let levels: [String: Logger.Level] = ["debug": .debug, "info": .info, "warning": .warning, "error": .error]
        guard let line = try? decoder.decode(Line.self, from: data),
              let date = timestamp.date(from: line.ts), let level = levels[line.level] else { return nil }
        return LogEntry(id: data.startIndex + 1, date: date, level: level, category: line.category,
                        thread: line.thread, location: line.loc, message: line.msg)
    }

    private func read<T: Sendable>(_ body: @escaping @Sendable (Data) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    self.flush()
                    let data = FileManager.default.fileExists(atPath: Self.fileURL.path)
                        ? try Data(contentsOf: Self.fileURL) : Data()
                    continuation.resume(returning: try body(data))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        let chunk = pending
        pending.removeAll(keepingCapacity: true)
        do {
            let handle = try openHandle()
            var data = Data(capacity: chunk.reduce(0) { $0 + $1.count + 1 })
            for line in chunk {
                data.append(line)
                data.append(0x0A)
            }
            try handle.write(contentsOf: data)
            if try handle.offset() > Self.maxBytes { try compact() }
        } catch {
            oslog.error("flush failed: \(error, privacy: .public)")
            handle = nil
        }
    }

    private func openHandle() throws -> FileHandle {
        if let handle { return handle }
        let fm = FileManager.default
        if !fm.fileExists(atPath: Self.directory.path) {
            try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: Self.fileURL.path) {
            fm.createFile(atPath: Self.fileURL.path, contents: nil)
        }
        try? AppStoragePaths.excludeFromBackup(Self.fileURL)
        let h = try FileHandle(forWritingTo: Self.fileURL)
        try h.seekToEnd()
        handle = h
        return h
    }

    private func compact() throws {
        try handle?.close()
        handle = nil
        let data = try Data(contentsOf: Self.fileURL)
        let cut = data.count - Self.compactBytes
        let start = data[cut...].firstIndex(of: 0x0A).map { $0 + 1 } ?? cut
        try data[start...].write(to: Self.fileURL, options: .atomic)
    }
}
