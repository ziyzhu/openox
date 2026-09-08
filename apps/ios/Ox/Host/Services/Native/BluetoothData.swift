import Foundation

nonisolated enum BluetoothData {
    static func bytes(hex: String) throws -> Data {
        guard hex.count <= 1_024, hex.count.isMultiple(of: 2),
              hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw Failure("invalidHex", "Use an even number of hexadecimal digits, at most 512 bytes, without spaces or a prefix.")
        }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { throw Failure("invalidHex", "Invalid hexadecimal byte.") }
            data.append(byte)
            index = next
        }
        return data
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    struct Failure: LocalizedError, Sendable {
        let code: String
        let message: String

        init(_ code: String, _ message: String) {
            self.code = code
            self.message = message
        }

        var errorDescription: String? { "Bluetooth \(code): \(message)" }
    }

    struct Event: Encodable, Sendable {
        let sequence: Int
        let kind: String
        let deviceID: String
        let characteristicID: String?
        let valueHex: String?
        let errorCode: String?
        let timestamp: String
    }

    struct EventBuffer: Sendable {
        private(set) var sequence = 0
        private(set) var entries: [Event] = []
        let capacity: Int

        init(capacity: Int = 256) {
            self.capacity = max(1, capacity)
        }

        mutating func append(kind: String, deviceID: String, characteristicID: String? = nil, data: Data? = nil, errorCode: String? = nil) {
            sequence += 1
            entries.append(Event(
                sequence: sequence, kind: kind, deviceID: deviceID,
                characteristicID: characteristicID, valueHex: data.map(BluetoothData.hex),
                errorCode: errorCode, timestamp: ISO8601DateFormatter().string(from: Date())
            ))
            if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        }

        func dropped(after cursor: Int) -> Int {
            max(0, (entries.first?.sequence ?? (sequence + 1)) - cursor - 1)
        }

        mutating func clear() {
            entries.removeAll()
        }
    }
}

@MainActor
final class BluetoothRequest<Reply: Equatable & Sendable> {
    private struct Pending {
        let id: UUID
        let reply: Reply
        let continuation: CheckedContinuation<Void, Error>
        let timeout: Task<Void, Never>
    }

    private var pending: Pending?
    var reply: Reply? { pending?.reply }

    func wait(for reply: Reply, timeout: Duration, expired: @escaping @MainActor () -> Void, start: () -> Void) async throws {
        try Task.checkCancellation()
        guard pending == nil else { throw BluetoothData.Failure("busy", "Another Bluetooth request is pending.") }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    guard self?.pending?.id == id else { return }
                    expired()
                }
                pending = Pending(id: id, reply: reply, continuation: continuation, timeout: timer)
                start()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.pending?.id == id else { return }
                self?.cancel(CancellationError())
            }
        }
    }

    func complete(_ reply: Reply, error: Error? = nil) {
        guard pending?.reply == reply else { return }
        finish(error)
    }

    func cancel(_ error: Error) {
        finish(error)
    }

    private func finish(_ error: Error?) {
        guard let pending else { return }
        self.pending = nil
        pending.timeout.cancel()
        if let error { pending.continuation.resume(throwing: error) }
        else { pending.continuation.resume() }
    }
}
