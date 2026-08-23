import Foundation
import JavaScriptCore

nonisolated struct OxFunctionEnvironment {
    let makePromise: (Bool, @escaping @MainActor (@escaping (JSONValue?) -> Void, @escaping (String) -> Void) async -> Void) -> JSValue
    let bridge: () -> (any OxFunctionBridge)?

    func call(
        suspendingTimeout: Bool = false,
        _ body: @escaping @MainActor (any OxFunctionBridge) async throws -> JSONValue?
    ) -> JSValue {
        makePromise(suspendingTimeout) { resolve, reject in
            guard let bridge = bridge() else {
                reject("virtual machine bridge released")
                return
            }
            do {
                resolve(try await body(bridge))
            } catch {
                reject(error.localizedDescription)
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
