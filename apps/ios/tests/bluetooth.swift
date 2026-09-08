import Foundation

@main
struct BluetoothChecks {
    @MainActor
    static func main() async throws {
        let bytes = Data([0, 15, 128, 255])
        let decoded = try BluetoothData.bytes(hex: "000F80ff")
        precondition(decoded == bytes)
        precondition(BluetoothData.hex(bytes) == "000f80ff")
        let empty = try BluetoothData.bytes(hex: "")
        let maximum = try BluetoothData.bytes(hex: String(repeating: "ff", count: 512))
        precondition(empty.isEmpty)
        precondition(maximum.count == 512)
        for invalid in ["0", "gg", "ff ff", "0xff", "ＦＦ", String(repeating: "ff", count: 513)] {
            do {
                _ = try BluetoothData.bytes(hex: invalid)
                preconditionFailure("Accepted malformed or oversized bytes")
            } catch let error as BluetoothData.Failure {
                precondition(error.code == "invalidHex")
            }
        }

        var buffer = BluetoothData.EventBuffer(capacity: 2)
        buffer.append(kind: "value", deviceID: "one", characteristicID: "a", data: bytes)
        buffer.append(kind: "value", deviceID: "two", characteristicID: "b", data: Data([2]))
        buffer.append(kind: "disconnected", deviceID: "one")
        precondition(buffer.entries.map(\.sequence) == [2, 3])
        precondition(buffer.entries.map(\.deviceID) == ["two", "one"])
        precondition(buffer.dropped(after: 0) == 1)
        precondition(buffer.dropped(after: 2) == 0)
        buffer.clear()
        precondition(buffer.sequence == 3 && buffer.dropped(after: 1) == 2)
        buffer.append(kind: "servicesChanged", deviceID: "two")
        precondition(buffer.entries.first?.sequence == 4)
        precondition(buffer.dropped(after: 3) == 0)

        let request = BluetoothRequest<String>()
        let first = Task { @MainActor in
            try await request.wait(for: "read-a", timeout: .seconds(5), expired: { preconditionFailure("Completed request expired") }) {}
        }
        while request.reply == nil { await Task.yield() }
        request.complete("read-b")
        precondition(request.reply == "read-a")
        do {
            try await request.wait(for: "read-b", timeout: .seconds(1), expired: {}) {}
            preconditionFailure("Concurrent request replaced an active continuation")
        } catch let error as BluetoothData.Failure {
            precondition(error.code == "busy")
        }
        request.complete("read-a")
        request.complete("read-a")
        try await first.value
        precondition(request.reply == nil)

        let cancelled = Task { @MainActor in
            try await request.wait(for: "read-a", timeout: .seconds(5), expired: { preconditionFailure("Cancelled request expired") }) {}
        }
        while request.reply == nil { await Task.yield() }
        cancelled.cancel()
        do { try await cancelled.value; preconditionFailure("Cancellation succeeded") } catch is CancellationError {}
        precondition(request.reply == nil)

        do {
            try await request.wait(for: "read-a", timeout: .milliseconds(10), expired: {
                request.cancel(BluetoothData.Failure("timeout", "Timed out"))
            }) {}
            preconditionFailure("Missing callback succeeded")
        } catch let error as BluetoothData.Failure {
            precondition(error.code == "timeout")
        }
        try await request.wait(for: "read-a", timeout: .seconds(5), expired: { preconditionFailure("Replacement request expired") }) {
            request.complete("read-a")
        }
        do {
            try await request.wait(for: "write", timeout: .seconds(5), expired: {}) {
                request.cancel(BluetoothData.Failure("sessionClosed", "Closed"))
            }
            preconditionFailure("Session close succeeded")
        } catch let error as BluetoothData.Failure {
            precondition(error.code == "sessionClosed")
        }
        print("Bluetooth checks passed: byte validation, bounded events, callback matching, concurrency, cancellation, timeout, and session closure")
    }
}
