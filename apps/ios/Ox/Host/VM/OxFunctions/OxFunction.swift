import Foundation
import JavaScriptCore

nonisolated struct OxFunctionEnvironment {
    let makePromise: (Bool, @escaping @MainActor (@escaping (JSONValue?) -> Void, @escaping (OxFunctionError) -> Void) async -> Void) -> JSValue
    let bridge: () -> (any OxFunctionBridge)?

    func call(
        suspendingTimeout: Bool = false,
        _ body: @escaping @MainActor (any OxFunctionBridge) async throws -> JSONValue?
    ) -> JSValue {
        makePromise(suspendingTimeout) { resolve, reject in
            guard let bridge = bridge() else {
                reject(OxFunctionError(code: "runtime_unavailable", message: "The execution's Host bridge is no longer available.", recovery: "Start a new execution. Inspect any possible effects before retrying a write."))
                return
            }
            do {
                resolve(try await body(bridge))
            } catch {
                reject(.from(error))
            }
        }
    }
}

nonisolated struct OxFunction {
    let namespace: String?
    let schema: () -> [(String, JSONValue)]
    let installNatives: (JSContext, OxFunctionEnvironment) -> Void
    let jsFragment: String
}
