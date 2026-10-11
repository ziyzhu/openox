#if DEBUG && targetEnvironment(simulator)
import Foundation

extension OxHostProtocol {
    struct DurableStorageRequest: Codable {
        let caseID: UUID
        let action: String
        let testCase: Int?
        let mode: String?
        let scale: String?
        let iterations: Int?
        let benchmark: Int?
    }

    @MainActor
    static func handleDurableStorage(_ request: DurableStorageRequest, reply: OxHostRPC.Reply) {
        Task { @MainActor in
            do { reply.success(try await DurableStorageController.command(request)) }
            catch { reply.failure(error.localizedDescription) }
        }
    }
}

/// Published upstream storage workloads only. Never opens a Harness or a real Profile.
@MainActor
private enum DurableStorageController {
    static var running = false

    static func command(_ request: OxHostProtocol.DurableStorageRequest) async throws -> JSONValue {
        guard ["storageConformance", "storageBenchmark"].contains(request.action) else { throw RuntimeError.bridge("Unknown upstream storage diagnostic") }
        guard !running else { throw RuntimeError.bridge("Storage diagnostic is running") }
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "PiDurableDiagnostics/\(request.action)/\(request.caseID.uuidString)")
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw RuntimeError.bridge("Storage diagnostic requires a fresh fixture") }
        running = true // Reserve before any await; never overlap storage workloads.
        defer { running = false }
        let runtime = DurableRuntime(databaseURL: directory.appending(path: "session.sqlite"), storageDiagnostics: true)
        do {
            let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
            let result = try await runtime.command(json, entry: request.action)
            await runtime.dispose() // The upstream runner has already closed SQLite.
            try removeFixture(directory)
            Log.agent.info("PiDurable upstream storage completed action=\(request.action) case=\(request.caseID)")
            return try JSONDecoder().decode(JSONValue.self, from: Data(result.utf8))
        } catch {
            await runtime.dispose()
            do { try removeFixture(directory) }
            catch { Log.agent.warning("PiDurable storage diagnostic cleanup failed: \(error.localizedDescription)") }
            throw error
        }
    }

    private static func removeFixture(_ directory: URL) throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}
#endif
