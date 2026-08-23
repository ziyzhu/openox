import Foundation
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

    private struct Line: Encodable {
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

    func url() -> URL? {
        queue.sync { flush() }
        return FileManager.default.fileExists(atPath: Self.fileURL.path) ? Self.fileURL : nil
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
