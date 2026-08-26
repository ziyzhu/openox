import Foundation
@preconcurrency import JavaScriptCore
import Synchronization

nonisolated final class VirtualMachineThread: Thread, @unchecked Sendable {
    private(set) var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    static let shared: VirtualMachineThread = {
        let t = VirtualMachineThread()
        t.name = "agent-javascript"
        t.qualityOfService = .userInitiated
        t.start()
        t.ready.wait()
        return t
    }()

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        var srcCtx = CFRunLoopSourceContext()
        let source = CFRunLoopSourceCreate(nil, 0, &srcCtx)
        CFRunLoopAddSource(runLoop, source, .defaultMode)
        ready.signal()
        while !isCancelled {
            let r = CFRunLoopRunInMode(.defaultMode, 1e9, false)
            if r == .stopped { break }
        }
    }

    func perform(_ block: @escaping @Sendable () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }
}

nonisolated public struct VirtualMachineLog: Sendable, Equatable {
    public let level: String
    public let message: String
}

nonisolated public struct VirtualMachineOutput: Sendable {
    public let value: JSONValue?
    public let logs: [VirtualMachineLog]
}

public actor VirtualMachine {
    nonisolated public static let defaultTimeout: TimeInterval = 60
    nonisolated public let fileSystem = VirtualFileSystem()

    private let runtime: VirtualMachineRuntime
    private var tail: Task<Void, Never>?

    public init() {
        runtime = VirtualMachineRuntime()
    }

    public enum Error: LocalizedError {
        case noContext
        case js(String, logs: [VirtualMachineLog] = [])
        case timeout(TimeInterval, logs: [VirtualMachineLog] = [])
        public var errorDescription: String? {
            switch self {
            case .noContext: return "snippet runtime: failed to create JSContext"
            case .js(let s, _): return s
            case .timeout(let t, _): return "snippet timed out after \(Int(t))s"
            }
        }
        public var logs: [VirtualMachineLog] {
            switch self {
            case .noContext: return []
            case .js(_, let l), .timeout(_, let l): return l
            }
        }
    }

    public func run(
        source: String,
        bridge: any OxFunctionBridge,
        timeout: TimeInterval = VirtualMachine.defaultTimeout
    ) async throws -> VirtualMachineOutput {
        let previous = tail
        let runtime = runtime
        let execution = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await runtime.run(source: source, bridge: bridge, timeout: timeout)
        }
        tail = Task { _ = try? await execution.value }
        return try await withTaskCancellationHandler {
            try await execution.value
        } onCancel: {
            execution.cancel()
        }
    }
}

nonisolated private final class VirtualMachineRuntime: @unchecked Sendable {
    private var thread: VirtualMachineThread { VirtualMachineThread.shared }
    private var vm: JSVirtualMachine?

    func run(source: String, bridge: any OxFunctionBridge, timeout: TimeInterval) async throws -> VirtualMachineOutput {
        let handle = RunHandle()
        let environment = RunEnvironment(bridge: bridge, handle: handle)
        let started = Date()
        let elapsedMs: @Sendable () -> Int = { Int(Date().timeIntervalSince(started) * 1000) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<VirtualMachineOutput, any Swift.Error>) in
                handle.continuation = cont
                guard !Task.isCancelled else {
                    handle.cancel()
                    return
                }

                handle.timeoutTask = Task {
                    while !Task.isCancelled {
                        let remaining = handle.remainingTimeout(timeout, started: started)
                        guard remaining > 0 else {
                            Log.agent.error("snippet timed out after \(Int(timeout))s ms=\(elapsedMs()) bridgeLogs=\(handle.snapshotLogs().count)")
                            handle.settle(.failure(VirtualMachine.Error.timeout(timeout, logs: handle.snapshotLogs())))
                            return
                        }
                        try? await Task.sleep(for: .seconds(remaining))
                    }
                }

                thread.perform { [weak self] in
                    guard !handle.isSettled else { return }
                    guard let self else {
                        Log.agent.error("snippet: VirtualMachine deallocated before run")
                        handle.settle(.failure(VirtualMachine.Error.noContext))
                        return
                    }
                    let contextStarted = Date()
                    guard let ctx = self.makeContext(environment: environment) else {
                        Log.agent.error("snippet: failed to create JSContext")
                        handle.settle(.failure(VirtualMachine.Error.noContext))
                        return
                    }
                    let contextSetupMs = Int(Date().timeIntervalSince(contextStarted) * 1000)
                    Log.agent.info("snippet run start bytes=\(source.utf8.count) contextSetupMs=\(contextSetupMs)")

                    var pendingException: String?
                    ctx.exceptionHandler = { _, exception in
                        pendingException = exception?.toString() ?? "unknown JS exception"
                    }

                    let resolve: @convention(block) (JSValue) -> Void = { value in
                        Log.agent.info("snippet run ok ms=\(elapsedMs()) logs=\(handle.snapshotLogs().count)")
                        handle.settle(.success(VirtualMachineOutput(value: jsValueToJSON(value), logs: handle.snapshotLogs())))
                    }
                    let reject: @convention(block) (JSValue) -> Void = { err in
                        let msg = err.toString() ?? "snippet rejected with non-Error"
                        Log.agent.error("snippet rejected ms=\(elapsedMs()): \(msg)")
                        handle.settle(.failure(VirtualMachine.Error.js(msg, logs: handle.snapshotLogs())))
                    }
                    ctx.setObject(resolve as AnyObject, forKeyedSubscript: "__nativeResolve" as NSString)
                    ctx.setObject(reject  as AnyObject, forKeyedSubscript: "__nativeReject"  as NSString)

                    let wrapped = "(async () => {\n\(source)\n})().then(__nativeResolve, __nativeReject);"
                    ctx.evaluateScript(wrapped)

                    if let exc = pendingException {
                        Log.agent.error("snippet sync exception: \(exc)")
                        handle.settle(.failure(VirtualMachine.Error.js(exc, logs: handle.snapshotLogs())))
                    }
                }
            }
        } onCancel: {
            Log.agent.info("snippet cancelled ms=\(elapsedMs()) bridgeLogs=\(handle.snapshotLogs().count)")
            handle.cancel()
        }
    }

    private func installOxBridge(into ctx: JSContext, environment: RunEnvironment) {
        let thread = self.thread

        let makePromise: (Bool, @escaping @MainActor (@escaping (JSONValue?) -> Void, @escaping (String) -> Void) async -> Void) -> JSValue = { [weak ctx] suspendingTimeout, body in
            guard let ctx, let handle = environment.handle, !handle.isSettled else {
                Log.agent.debug("virtual machine bridge promise requested with no active run — leaked async?")
                return JSValue(undefinedIn: nil)
            }
            let callbacks = JSPromiseCallbacks()
            let executor: @convention(block) (JSValue, JSValue) -> Void = { res, rej in
                callbacks.resolve = res
                callbacks.reject = rej
            }
            let promiseCtor = ctx.objectForKeyedSubscript("Promise")!
            let promise = promiseCtor.construct(withArguments: [unsafeBitCast(executor, to: AnyObject.self)])!

            if suspendingTimeout { handle.suspendTimeout() }
            let task = Task { @MainActor in
                defer {
                    if suspendingTimeout { handle.resumeTimeout() }
                }
                await body(
                    { value in
                        if handle.isSettled { return }
                        thread.perform { callbacks.resolve?.call(withArguments: [value?.toAny() ?? NSNull()]) }
                    },
                    { msg in
                        if handle.isSettled { return }
                        thread.perform {
                            guard let owningCtx = callbacks.reject?.context else { return }
                            let err = JSValue(newErrorFromMessage: msg, in: owningCtx)
                                ?? JSValue(object: msg, in: owningCtx)!
                            callbacks.reject?.call(withArguments: [err])
                        }
                    }
                )
            }
            handle.trackBridgeTask(task)
            return promise
        }

        let env = OxFunctionEnvironment(makePromise: makePromise, bridge: { environment.activeBridge })

        for tool in OxFunctionCatalog.all {
            tool.installNatives(ctx, env)
        }

        let helpCatalog = OxFunctionCatalog.build()
        let helpTextCatalog = OxFunctionCatalog.buildHelpText()
        ctx.setObject(helpCatalog.toAny(), forKeyedSubscript: "__oxHelpCatalog" as NSString)
        ctx.setObject(helpTextCatalog.toAny(), forKeyedSubscript: "__oxHelpTextCatalog" as NSString)
        let helpTextCharacters = helpTextCatalog.objectValue?.values.reduce(0) { $0 + ($1.stringValue?.count ?? 0) } ?? 0
        Log.agent.debug("virtual machine help jsonChars=\(helpCatalog.jsonString().count) textChars=\(helpTextCharacters)")

        var rootFragments: [String] = []
        var byNamespace: [String: [String]] = [:]
        var namespaces: [String] = []
        for tool in OxFunctionCatalog.all {
            guard let namespace = tool.namespace else {
                rootFragments.append(tool.jsFragment)
                continue
            }
            byNamespace[namespace, default: []].append(tool.jsFragment)
            if !namespaces.contains(namespace) { namespaces.append(namespace) }
        }
        let nsBlocks = namespaces.compactMap { ns -> String? in
            guard let frags = byNamespace[ns], !frags.isEmpty else { return nil }
            return "  \(ns): {\n\(frags.joined(separator: ",\n"))\n  }"
        }
        let oxMembers = (rootFragments + nsBlocks).joined(separator: ",\n")
        ctx.evaluateScript("""
        const __oxHelpDetail = name => {
          const help = __oxHelpTextCatalog[name];
          return help == null ? '' : '\\n\\nFull help:\\n' + help;
        };
        const __oxValueType = value => {
          if (value === null) return 'null';
          if (Array.isArray(value)) return 'array';
          if (typeof value === 'number' && Number.isInteger(value)) return 'integer';
          return typeof value;
        };
        const __oxMatchesType = (value, type) => {
          if (type === 'null') return value === null;
          if (type === 'array') return Array.isArray(value);
          if (type === 'object') return value !== null && typeof value === 'object' && !Array.isArray(value);
          if (type === 'integer') return typeof value === 'number' && Number.isInteger(value);
          if (type === 'number') return typeof value === 'number' && Number.isFinite(value);
          return typeof value === type;
        };
        const __oxValidationError = (value, schema, path) => {
          if (schema == null || typeof schema !== 'object') return null;
          if (Array.isArray(schema.oneOf)) {
            const errors = schema.oneOf.map(candidate => __oxValidationError(value, candidate, path));
            if (errors.some(error => error == null)) return null;
            return errors[0] ?? `${path || 'value'} is invalid.`;
          }
          const types = schema.type == null ? [] : Array.isArray(schema.type) ? schema.type : [schema.type];
          if (types.length && !types.some(type => __oxMatchesType(value, type))) {
            const expected = types.map(type => type === 'integer' ? 'an integer' : `a ${type}`).join(' or ');
            return `${path || 'value'} must be ${expected}; got ${__oxValueType(value)}.`;
          }
          if (Array.isArray(schema.enum) && !schema.enum.some(candidate => Object.is(candidate, value))) {
            return `${path || 'value'} must be one of ${schema.enum.map(candidate => JSON.stringify(candidate)).join(', ')}.`;
          }
          if (value !== null && typeof value === 'object' && !Array.isArray(value)) {
            const properties = schema.properties ?? {};
            for (const required of schema.required ?? []) {
              if (!Object.prototype.hasOwnProperty.call(value, required) || value[required] === undefined) {
                return `'${path ? `${path}.` : ''}${required}' is required.`;
              }
            }
            if (schema.additionalProperties === false) {
              const unknown = Object.keys(value).filter(key => !Object.prototype.hasOwnProperty.call(properties, key));
              if (unknown.length) return `unknown option '${unknown.sort().join(', ')}'.`;
            }
            for (const [key, item] of Object.entries(value)) {
              if (item === undefined || !Object.prototype.hasOwnProperty.call(properties, key)) continue;
              const error = __oxValidationError(item, properties[key], path ? `${path}.${key}` : key);
              if (error != null) return error;
            }
          }
          if (Array.isArray(value) && schema.items != null) {
            if (schema.minItems != null && value.length < schema.minItems || schema.maxItems != null && value.length > schema.maxItems) {
              const range = schema.minItems != null && schema.maxItems != null
                ? `${schema.minItems}–${schema.maxItems}`
                : schema.minItems != null ? `at least ${schema.minItems}` : `at most ${schema.maxItems}`;
              return `'${path}' must contain ${range} items.`;
            }
            if (schema.uniqueItems === true && new Set(value.map(item => JSON.stringify(item))).size !== value.length) {
              return `'${path}' must contain unique items.`;
            }
            for (let index = 0; index < value.length; index += 1) {
              const error = __oxValidationError(value[index], schema.items, `${path}[${index}]`);
              if (error != null) return error;
            }
          }
          if (typeof value === 'string') {
            if (schema.minLength != null && value.length < schema.minLength || schema.maxLength != null && value.length > schema.maxLength) {
              const range = schema.minLength != null && schema.maxLength != null
                ? `${schema.minLength}–${schema.maxLength}`
                : schema.minLength != null ? `at least ${schema.minLength}` : `at most ${schema.maxLength}`;
              return `'${path}' must contain ${range} characters.`;
            }
          }
          if (typeof value === 'number') {
            if (schema.minimum != null && value < schema.minimum) return `'${path}' must be at least ${schema.minimum}.`;
            if (schema.maximum != null && value > schema.maximum) return `'${path}' must be at most ${schema.maximum}.`;
          }
          return null;
        };
        const __oxOptions = (value, name) => {
          if (value == null || typeof value !== 'object' || Array.isArray(value)) {
            throw new TypeError(name + ' expects one options object.' + __oxHelpDetail(name));
          }
          const error = __oxValidationError(value, __oxHelpCatalog[name]?.inputSchema, '');
          if (error != null) throw new TypeError(name + ': ' + error + __oxHelpDetail(name));
          return value;
        };
        const ox = {
        \(oxMembers)
        };
        const __oxAttachHelp = (value, prefix = 'ox') => {
          for (const [key, member] of Object.entries(value)) {
            const name = `${prefix}.${key}`;
            if (typeof member === 'function') {
              const schema = __oxHelpCatalog[name];
              if (schema != null) {
                Object.defineProperty(member, 'help', {
                  value: () => __oxHelpTextCatalog[name],
                  enumerable: false,
                  writable: false,
                  configurable: false,
                });
              }
            } else if (member != null && typeof member === 'object') {
              __oxAttachHelp(member, name);
            }
          }
        };
        __oxAttachHelp(ox);
        Object.defineProperty(globalThis, 'ox', { value: ox, writable: false, configurable: false });
        """)
        if let exception = ctx.exception?.toString() {
            Log.agent.error("virtual machine bridge install failed: \(exception)")
        }
    }

    private func makeContext(environment: RunEnvironment) -> JSContext? {
        let vm = vm ?? JSVirtualMachine()
        self.vm = vm
        guard let ctx = JSContext(virtualMachine: vm) else { return nil }
        installOxBridge(into: ctx, environment: environment)
        installConsole(into: ctx, environment: environment)
        return ctx
    }

    private func installConsole(into ctx: JSContext, environment: RunEnvironment) {
        let log: @convention(block) (String, JSValue) -> Void = { level, args in
            guard let handle = environment.handle, !handle.isSettled else {
                Log.agent.debug("virtual machine console.\(level) with no active run — leaked async?")
                return
            }
            let count = Int(args.objectForKeyedSubscript("length")?.toInt32() ?? 0)
            let parts = (0..<count).map { i -> String in
                let v = args.atIndex(i) ?? JSValue(undefinedIn: args.context)!
                return jsValueToLogString(v)
            }
            handle.appendLog(level: level, message: parts.joined(separator: " "))
        }
        ctx.setObject(log as AnyObject, forKeyedSubscript: "__nativeLog" as NSString)
        ctx.evaluateScript("""
        const console = Object.freeze({
          log:   (...a) => __nativeLog('log',   a),
          info:  (...a) => __nativeLog('info',  a),
          warn:  (...a) => __nativeLog('warn',  a),
          error: (...a) => __nativeLog('error', a),
          debug: (...a) => __nativeLog('debug', a),
        });
        Object.defineProperty(globalThis, 'console', { value: console, writable: false, configurable: false });
        """)
    }
}

nonisolated private final class RunEnvironment: @unchecked Sendable {
    weak var bridge: (any OxFunctionBridge)?
    weak var handle: RunHandle?

    init(bridge: any OxFunctionBridge, handle: RunHandle) {
        self.bridge = bridge
        self.handle = handle
    }

    var activeBridge: (any OxFunctionBridge)? {
        guard let handle, !handle.isSettled else { return nil }
        return bridge
    }
}

nonisolated private final class JSPromiseCallbacks: @unchecked Sendable {
    var resolve: JSValue?
    var reject: JSValue?
}

nonisolated private func jsValueToLogString(_ v: JSValue) -> String {
    if v.isUndefined { return "undefined" }
    if v.isNull { return "null" }
    if v.isString { return v.toString() ?? "" }
    if v.isBoolean || v.isNumber { return v.toString() ?? "" }
    if let ctx = v.context,
       let json = ctx.objectForKeyedSubscript("JSON"),
       let stringify = json.objectForKeyedSubscript("stringify"),
       let result = stringify.call(withArguments: [v]),
       result.isString {
        return result.toString() ?? (v.toString() ?? "")
    }
    return v.toString() ?? ""
}

nonisolated private final class RunHandle: @unchecked Sendable {
    private struct State {
        var settled = false
        var bridgeTasks: [Task<Void, Never>] = []
        var logs: [VirtualMachineLog] = []
        var logBytes = 0
        var continuation: CheckedContinuation<VirtualMachineOutput, any Swift.Error>?
        var timeoutTask: Task<Void, Never>?
        var timeoutSuspensions = 0
        var timeoutSuspendedAt: Date?
        var timeoutSuspendedDuration: TimeInterval = 0
    }
    private let state = Mutex(State())

    func appendLog(level: String, message: String) {
        let exceeded = state.withLock { state in
            guard !state.settled else { return false }
            let bytes = message.utf8.count + level.utf8.count + 4
            guard state.logBytes + bytes <= ArtifactLimits.fileBytes else { return true }
            state.logBytes += bytes
            state.logs.append(VirtualMachineLog(level: level, message: message))
            return false
        }
        if exceeded {
            settle(.failure(VirtualMachine.Error.js("JavaScript console output exceeds the 32 MiB memory safety limit. Filter results before printing.", logs: snapshotLogs())))
        }
    }

    func snapshotLogs() -> [VirtualMachineLog] {
        state.withLock { $0.logs }
    }

    var continuation: CheckedContinuation<VirtualMachineOutput, any Swift.Error>? {
        get { state.withLock { $0.continuation } }
        set { state.withLock { $0.continuation = newValue } }
    }
    var timeoutTask: Task<Void, Never>? {
        get { state.withLock { $0.timeoutTask } }
        set { state.withLock { $0.timeoutTask = newValue } }
    }
    var isSettled: Bool {
        state.withLock { $0.settled }
    }

    func suspendTimeout() {
        state.withLock { state in
            guard !state.settled else { return }
            state.timeoutSuspensions += 1
            if state.timeoutSuspensions == 1 { state.timeoutSuspendedAt = Date() }
        }
    }

    func resumeTimeout() {
        state.withLock { state in
            guard !state.settled, state.timeoutSuspensions > 0 else { return }
            state.timeoutSuspensions -= 1
            guard state.timeoutSuspensions == 0, let suspendedAt = state.timeoutSuspendedAt else { return }
            state.timeoutSuspendedDuration += Date().timeIntervalSince(suspendedAt)
            state.timeoutSuspendedAt = nil
        }
    }

    func remainingTimeout(_ timeout: TimeInterval, started: Date) -> TimeInterval {
        state.withLock { state in
            let currentSuspension = state.timeoutSuspendedAt.map { Date().timeIntervalSince($0) } ?? 0
            let activeDuration = Date().timeIntervalSince(started) - state.timeoutSuspendedDuration - currentSuspension
            return timeout - activeDuration
        }
    }

    func settle(_ result: Result<VirtualMachineOutput, any Swift.Error>) {
        let pending = state.withLock { state -> (CheckedContinuation<VirtualMachineOutput, any Swift.Error>, Task<Void, Never>?, [Task<Void, Never>])? in
            guard !state.settled, let continuation = state.continuation else { return nil }
            state.settled = true
            let timeout = state.timeoutTask
            let bridgeTasks = state.bridgeTasks
            state.continuation = nil
            state.timeoutTask = nil
            state.bridgeTasks.removeAll()
            return (continuation, timeout, bridgeTasks)
        }
        guard let (continuation, timeout, bridgeTasks) = pending else { return }
        timeout?.cancel()
        for task in bridgeTasks { task.cancel() }
        continuation.resume(with: result)
    }

    func cancel() {
        settle(.failure(CancellationError()))
    }

    func trackBridgeTask(_ task: Task<Void, Never>) {
        let accepted = state.withLock { state in
            guard !state.settled else { return false }
            state.bridgeTasks.append(task)
            return true
        }
        if !accepted { task.cancel() }
    }

}

nonisolated func jsValueToJSON(_ v: JSValue) -> JSONValue? {
    if v.isUndefined || v.isNull { return nil }
    if v.isBoolean { return .bool(v.toBool()) }
    if v.isNumber, let number = v.toNumber() { return .from(number) }
    if v.isString, let string = v.toString() { return .string(string) }
    guard let object = v.toObject() else { return nil }
    return .from(object)
}
