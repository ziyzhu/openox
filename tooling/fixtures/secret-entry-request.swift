import Foundation

typealias RepositoryTokenValidation = @Sendable (String, String) async throws -> Void

@MainActor
enum Secret {
    static var writes: [(String, String, String)] = []

    static func validateDisplayName(_ value: String) throws {
        guard !value.isEmpty else { throw RuntimeError.bridge("Empty display name") }
    }

    static func set(key: String, displayName: String, value: String) throws {
        writes.append((key, displayName, value))
    }
}

enum RuntimeError {
    static func bridge(_ message: String) -> NSError {
        NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@MainActor
final class ValidationProbe {
    var attempts = 0
    var received = ""
    var displayName = ""
    var gate: CheckedContinuation<Void, Never>?

    func validate(_ value: String, _ name: String) async throws {
        displayName = name
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
        let malformed = SecretEntryRequest { try await probe.validate($0, $1) }
        for value in [#"{"other":"synthetic"}"#, #"{"token":"synthetic","extra":"field"}"#] {
            malformed.submit(displayName: "Publication name", value: value) { preconditionFailure("Invalid fields were saved") }
            await until { malformed.state == .editing }
            precondition(malformed.error != nil && probe.attempts == 0)
        }
        let request = SecretEntryRequest { try await probe.validate($0, $1) }
        var completions = 0
        request.submit(displayName: "Publication name", value: #"{"token":" invalid "}"#) { completions += 1 }
        request.submit(displayName: "Publication name", value: #"{"token":"duplicate"}"#) { completions += 1 }
        await until { probe.gate != nil }
        precondition(probe.attempts == 1 && probe.received == "invalid" && probe.displayName == "Publication name")
        probe.release()
        await until { request.state == .editing }
        precondition(request.error == "Invalid test value" && completions == 0)
        request.submit(displayName: "Publication name", value: #"{"token":" synthetic-success\n"}"#) { completions += 1 }
        await until { probe.gate != nil }
        probe.release()
        await until { request.state == .finished }
        precondition(completions == 1 && request.error == nil)

        let cancelled = SecretEntryRequest { try await probe.validate($0, $1) }
        cancelled.submit(displayName: "Publication name", value: #"{"token":"synthetic-success"}"#) { completions += 1 }
        await until { probe.gate != nil }
        cancelled.cancel()
        probe.release()
        for _ in 0..<100 { await Task.yield() }
        precondition(cancelled.state == .finished && completions == 1)
        let attempts = probe.attempts
        cancelled.submit(displayName: "Publication name", value: #"{"token":"synthetic-success"}"#) { completions += 1 }
        for _ in 0..<100 { await Task.yield() }
        precondition(probe.attempts == attempts && completions == 1)

        let named = SecretEntryRequest(key: "fixture")
        named.submit(displayName: "Fixture", value: "{\"token\":\"synthetic\"}") { completions += 1 }
        await until { named.state == .finished }
        precondition(Secret.writes.count == 1 && Secret.writes[0].0 == "fixture" && completions == 2)
        print("PASS secret entry retry, duplicate submission, cancellation, and named save")
    }
}
