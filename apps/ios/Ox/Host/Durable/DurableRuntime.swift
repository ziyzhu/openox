import Foundation
import CryptoKit
@preconcurrency import JavaScriptCore

/// Separate trusted context, never reachable through model-authored snippet execution.
/// Apple: JSContext / JSVirtualMachine; native callbacks must not retain their owning context.
nonisolated final class DurableRuntime: @unchecked Sendable {
    typealias NativeHandler = @Sendable (String, JSONValue, @escaping @Sendable (JSONValue) -> Void) async throws -> JSONValue
    private let nativeHandler: NativeHandler?
    private let queue = DispatchQueue(label: "ox.durable.javascript", qos: .userInitiated)
    private let nativeQueue = DispatchQueue(label: "ox.durable.native", qos: .userInitiated)
    private let database: DurableDatabase
    private let artifacts: DurableArtifactStore?
    private let storageDiagnostics: Bool
    private var context: JSContext?
    private struct TimerHandle {
        let work: DispatchWorkItem
        let callback: JSValue
    }
    private var timers: [Int: TimerHandle] = [:]
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var calls: [Int: CheckedContinuation<String, any Error>] = [:]
    private var nextID = 0
    private var nextTimerID = 0
    private var cancelledIDs: Set<Int> = []
    private var fatalError: String?

    init(databaseURL: URL, storageDiagnostics: Bool = false, artifactRoot: URL? = nil, nativeHandler: NativeHandler? = nil) {
        artifacts = artifactRoot.map(DurableArtifactStore.init)
        database = DurableDatabase(url: databaseURL)
        self.nativeHandler = nativeHandler
        self.storageDiagnostics = storageDiagnostics
    }

    func command(_ json: String, entry: String = "agentCommand") async throws -> String {
        let entries = storageDiagnostics ? ["storageConformance", "storageBenchmark"] : ["agentCommand"]
        guard entries.contains(entry) else { throw failure("Unavailable trusted entry point") }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    if let fatalError { throw failure(fatalError) }
                    if context == nil { try install() }
                    nextID += 1
                    calls[nextID] = continuation
                    context?.objectForKeyedSubscript("__oxDurableCommand")?.call(withArguments: [entry, json, nextID])
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func command(_ value: JSONValue) async throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(try await command(value.jsonString()).utf8))
    }

    func publishArtifact(data: Data, filename: String) async throws -> JSONValue {
        _ = try ArtifactStore.validatedFilename(filename)
        let request = JSONValue.object(["action": .string("fileWriteBinary"), "path": .string("artifacts/" + filename),
                                        "base64": .string(data.base64EncodedString())])
        return try JSONDecoder().decode(JSONValue.self, from: Data(try await command(request.jsonString()).utf8))
    }

    func readPayload(id: String) async throws -> String {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "payload", parts[1].count == 64,
              parts[1].allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              let offset = Int(parts[2]), let length = Int(parts[3]), offset >= 0, length >= 0,
              length <= 32 * 1024 * 1024 else { throw failure("Invalid or oversized bounded payload reference") }
        let result = try await command(.object(["action": .string("payloadRead"),
            "path": .string("artifacts/payload-" + parts[1] + ".json"), "offset": .int(offset), "length": .int(length)]))
        guard let encoded = result.objectValue?["base64"]?.stringValue, let data = Data(base64Encoded: encoded),
              let text = String(data: data, encoding: .utf8) else { throw failure("Payload is not valid UTF-8") }
        return text
    }

    func readArtifact(_ artifact: JSONValue) async throws -> Data {
        guard let fields = artifact.objectValue, let path = fields["path"]?.stringValue, let size = fields["size"]?.intValue,
              let digest = fields["sha256"]?.stringValue, (0...32 * 1024 * 1024).contains(size) else { throw failure("Invalid artifact descriptor") }
        return try await withCheckedThrowingContinuation { continuation in
            nativeQueue.async { [self] in
                do {
                    guard let artifacts else { throw failure("No physical artifact owner") }
                    guard let token = try artifacts.perform(["op": "open", "path": path, "size": size]) as? String else { throw failure("Cannot pin artifact") }
                    defer { _ = try? artifacts.perform(["op": "release", "token": token]) }
                    var data = Data()
                    data.reserveCapacity(size)
                    while data.count < size {
                        let length = min(128 * 1024, size - data.count)
                        guard let bytes = try artifacts.perform(["op": "read", "token": token, "offset": data.count, "length": length]) as? [UInt8], bytes.count == length else {
                            throw failure("Artifact read incomplete")
                        }
                        data.append(contentsOf: bytes)
                    }
                    _ = try artifacts.perform(["op": "verify", "token": token, "sha256": digest])
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func readArtifact(descriptor: JSONValue) async throws -> Data { try await readArtifact(descriptor) }

    /// Only after Harness.close() has joined all invocations and closed its connection.
    func dispose() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                fatalError = "Durable runtime closed; reacquire after reopening"
                for call in calls.values { call.resume(throwing: failure(fatalError!)) }
                calls.removeAll()
                for id in Array(timers.keys) { clearTimer(id) }
                for task in tasks.values { task.cancel() }
                tasks.removeAll()
                nativeQueue.sync {
                    do {
                        _ = try database.perform("close", sql: "", params: [])
                        artifacts?.close()
                    } catch { Log.agent.error("PiDurable database disposal failed; artifact ownership retained: \(error.localizedDescription)") }
                }
                context = nil
                continuation.resume()
            }
        }
    }

    private func install() throws {
        guard let vm = JSVirtualMachine(), let ctx = JSContext(virtualMachine: vm) else { throw failure("Cannot create durable context") }
        context = ctx
        ctx.exceptionHandler = { [weak self] _, error in
            guard let self else { return }
            let message = (error?.toString() ?? "Unknown JavaScript exception") + "\n" + (error?.objectForKeyedSubscript("stack")?.toString() ?? "")
            self.fatalError = message
            let calls = self.calls
            self.calls.removeAll()
            for call in calls.values { call.resume(throwing: self.failure(message)) }
            Log.agent.error("PiDurable JavaScript exception: \(message)")
        }
        let request: @convention(block) (Int, String) -> Void = { [weak self] id, json in
            guard let self else { return }
            if id == 0 {
                if let data = json.data(using: .utf8), let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let params = request["params"] as? [String: Any], let id = params["id"] as? Int {
                    self.cancelledIDs.insert(id)
                    self.tasks[id]?.cancel()
                }
                return
            }
            self.nativeQueue.async { [weak self] in self?.performNative(id: id, json: json) }
        }
        let complete: @convention(block) (Int, JSValue, JSValue) -> Void = { [weak self] id, json, error in
            guard let self, let call = self.calls.removeValue(forKey: id) else { return }
            if !error.isNull && !error.isUndefined { call.resume(throwing: self.failure(error.toString())) }
            else { call.resume(returning: json.toString() ?? "null") }
        }
        let timer: @convention(block) (JSValue, Double) -> Int = { [weak self] callback, ms in
            guard let self else { return 0 }
            self.nextTimerID += 1
            let id = self.nextTimerID
            // Only the live timer table retains JSValue. Scheduled work captures no context/callback;
            // clearing a long timer releases its callback immediately, not at the scheduled deadline.
            let work = DispatchWorkItem { [weak self] in
                guard let self, let timer = self.timers.removeValue(forKey: id) else { return }
                timer.callback.call(withArguments: [])
            }
            self.timers[id] = TimerHandle(work: work, callback: callback)
            self.queue.asyncAfter(deadline: .now() + max(0.001, ms / 1000), execute: work)
            return id
        }
        let clear: @convention(block) (Int) -> Void = { [weak self] id in self?.clearTimer(id) }
        let log: @convention(block) (String, String) -> Void = { level, message in
            switch level {
            case "error": Log.agent.error("PiDurable: \(message)")
            case "warning": Log.agent.warning("PiDurable: \(message)")
            default: Log.agent.debug("PiDurable: \(message)")
            }
        }
        ctx.setObject(log, forKeyedSubscript: "__oxDurableLog" as NSString)
        ctx.setObject(request, forKeyedSubscript: "__oxDurableRequest" as NSString)
        ctx.setObject(complete, forKeyedSubscript: "__oxDurableComplete" as NSString)
        ctx.setObject(timer, forKeyedSubscript: "__oxDurableTimer" as NSString)
        ctx.setObject(clear, forKeyedSubscript: "__oxDurableClearTimer" as NSString)
        // Benchmark-only synchronous monotonic clock, never installed in agent/snippet contexts.
        // https://developer.apple.com/documentation/dispatch/dispatchtime/uptimenanoseconds
        if storageDiagnostics {
            let now: @convention(block) () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }
            ctx.setObject(now, forKeyedSubscript: "__oxDurableNow" as NSString)
        }
        let resource = storageDiagnostics ? "harness-storage" : "harness"
        guard let url = Bundle.main.url(forResource: resource, withExtension: "js", subdirectory: "PiDurable.bundle") else {
            context = nil
            throw failure("Missing PiDurable.bundle; run bun run build:agent before building")
        }
        ctx.evaluateScript(try String(contentsOf: url, encoding: .utf8), withSourceURL: URL(string: "ox-trusted://harness.js"))
        ctx.evaluateScript("""
            globalThis.__oxDurableCommand = (entry, json, id) => {
                Promise.resolve().then(() => OxDurable[entry](JSON.parse(json))).then(
                    value => __oxDurableComplete(id, JSON.stringify(value), null),
                    error => __oxDurableComplete(id, null, String(error) + '\\n' + (error.stack || ''))
                );
            };
            """, withSourceURL: URL(string: "ox-trusted://durable-command.js"))
        if let fatalError { throw failure(fatalError) }
        Log.agent.info("PiDurable trusted context opened durable=1.0.0 ai=1.0.0 chord=1.0.0")
    }

    private func clearTimer(_ id: Int) {
        guard let timer = timers.removeValue(forKey: id) else { return }
        timer.work.cancel()
    }

    private func performNative(id: Int, json: String) {
        do {
            let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            guard let method = value?["method"] as? String, let params = value?["params"] as? [String: Any] else { throw failure("Invalid native request") }
            switch method {
            case "artifacts":
                guard let artifacts else { throw failure("Native artifact files are not installed in this runtime") }
                deliver(id, value: try artifacts.perform(params))
            case "sql":
                // One folder owner precedes SQLite initialization, including failed opens,
                // and remains held until the database closes.
                if params["op"] as? String != "close" { try artifacts?.acquire() }
                guard let op = params["op"] as? String, let sql = params["sql"] as? String, let bindings = params["params"] as? [Any] else { throw failure("Invalid SQL request") }
                deliver(id, value: try database.perform(op, sql: sql, params: bindings))
            case "uuid": deliver(id, value: UUID().uuidString)
            case "report":
                Log.agent.warning("PiDurable report: \(params["message"] as? String ?? "unknown")")
                deliver(id, value: NSNull())
            default:
                guard let nativeHandler else { throw failure("Unavailable native capability") }
                let params = JSONValue.from(params)
                queue.async { [weak self] in
                    guard let self else { return }
                    guard !self.cancelledIDs.contains(id) else { self.finish(id, json: "null", error: "Native operation cancelled"); return }
                    self.tasks[id] = Task { [weak self] in
                        do {
                            let value = try await nativeHandler(method, params) { [weak self] event in self?.stream(id, event: event) }
                            self?.finish(id, json: value.jsonString(), error: nil)
                        } catch { self?.finish(id, json: "null", error: error.localizedDescription) }
                    }
                }
            }
        } catch { finish(id, json: "null", error: error.localizedDescription) }
    }

    private func stream(_ id: Int, event: JSONValue) {
        let json = event.jsonString()
        queue.async { [weak self] in
            guard let self, self.tasks[id] != nil, !self.cancelledIDs.contains(id) else { return }
            self.context?.objectForKeyedSubscript("OxDurable")?.invokeMethod("streamEvent", withArguments: [id, json])
        }
    }

    private func deliver(_ id: Int, value: Any) {
        do { finish(id, json: try jsonString(value), error: nil) }
        catch { finish(id, json: "null", error: error.localizedDescription) }
    }
    private func finish(_ id: Int, json: String, error: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.tasks.removeValue(forKey: id)
            self.cancelledIDs.remove(id)
            self.context?.objectForKeyedSubscript("OxDurable")?.invokeMethod("deliver", withArguments: [id, json, error as Any? ?? NSNull()])
        }
    }
    private func jsonString(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), as: UTF8.self)
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "OxDurableRuntime", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
