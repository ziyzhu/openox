import Foundation

typealias RepositoryTokenValidation = @Sendable (String) async throws -> Void

@MainActor
enum Secret {
    static var writes: [(String, String, String)] = []

    static func set(key: String, displayName: String, value: String) throws {
        writes.append((key, displayName, value))
    }
}

@MainActor
final class ValidationProbe {
    var attempts = 0
    var received = ""
    var gate: CheckedContinuation<Void, Never>?

    func validate(_ value: String) async throws {
        attempts += 1
        received = value
        await withCheckedContinuation { gate = $0 }
        try Task.checkCancellation()
        if value != "synthetic-success" {
            throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid test value"])
        }
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

@main
struct SecretEntryRequestTests {
    @MainActor
    static func until(_ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        preconditionFailure("Request did not settle")
    }

    @MainActor
    static func main() async {
        let probe = ValidationProbe()
        let request = SecretEntryRequest { try await probe.validate($0) }
        var completions = 0
        request.submit(displayName: "", value: " invalid ") { completions += 1 }
        request.submit(displayName: "", value: "duplicate") { completions += 1 }
        await until { probe.gate != nil }
        precondition(probe.attempts == 1 && probe.received == "invalid")
        probe.release()
        await until { request.state == .editing }
        precondition(request.error == "Invalid test value" && completions == 0)
        request.submit(displayName: "", value: " synthetic-success\n") { completions += 1 }
        await until { probe.gate != nil }
        probe.release()
        await until { request.state == .finished }
        precondition(completions == 1 && request.error == nil)

        let cancelled = SecretEntryRequest { try await probe.validate($0) }
        cancelled.submit(displayName: "", value: "synthetic-success") { completions += 1 }
        await until { probe.gate != nil }
        cancelled.cancel()
        probe.release()
        for _ in 0..<100 { await Task.yield() }
        precondition(cancelled.state == .finished && completions == 1)
        let attempts = probe.attempts
        cancelled.submit(displayName: "", value: "synthetic-success") { completions += 1 }
        for _ in 0..<100 { await Task.yield() }
        precondition(probe.attempts == attempts && completions == 1)

        let named = SecretEntryRequest(key: "fixture")
        named.submit(displayName: "Fixture", value: "{\"token\":\"synthetic\"}") { completions += 1 }
        await until { named.state == .finished }
        precondition(Secret.writes.count == 1 && Secret.writes[0].0 == "fixture" && completions == 2)
        print("PASS secret entry retry, duplicate submission, cancellation, and named save")
    }
}
