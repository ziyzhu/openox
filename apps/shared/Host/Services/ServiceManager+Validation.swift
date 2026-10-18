import Foundation
import JavaScriptCore

extension ServiceManager {
    static func validateServiceSource(
        kind: ServicesMount.Kind,
        domain: String,
        read: ([String]) async throws -> Data
    ) async throws {
        switch kind {
        case .web, .api:
            let manifestData = try await read(["service.json"])
            let raw = try JSONDecoder().decode(JSONValue.self, from: manifestData)
            let definition = try ServiceDefinition(manifest: raw, repositoryID: Repository.localID, provenance: .local)
            guard definition.domain == domain, definition.isAPI == (kind == .api) else {
                throw Repository.Failure(message: "manifest identity does not match its directory")
            }
            let actionsData = try await read(["actions.js"])
            guard let source = String(data: actionsData, encoding: .utf8) else {
                throw Repository.Failure(message: "actions.js is not UTF-8")
            }
            let context = JSContext()!
            var syntaxError: String?
            context.exceptionHandler = { _, exception in syntaxError = exception?.toString() }
            let encoded = try JSONEncoder().encode(source)
            context.evaluateScript("new Function(\(String(decoding: encoded, as: UTF8.self)))")
            if let syntaxError {
                throw Repository.Failure(message: "actions.js syntax: \(syntaxError)")
            }
            syntaxError = nil
            context.evaluateScript(#"""
            globalThis.window = globalThis;
            window.ox = {
              __installations: 0,
              __registered: [],
              install(installer, ...extra) {
                this.__installations++;
                if (this.__installations > 1) throw new Error("service installer may run only once");
                if (typeof installer !== "function" || extra.length) throw new Error("window.ox.install takes only the installer");
                const names = this.__registered;
                const action = (name, definition) => {
                  if (typeof name !== "string" || !name) throw new Error("action name must be a non-empty string");
                  if (names.includes(name)) throw new Error(`duplicate action: ${name}`);
                  if (typeof definition?.invoke !== "function") throw new Error(`action ${name} has no invoke function`);
                  names.push(name);
                };
                const unavailable = () => { throw new Error("not callable during registration validation"); };
                const api = new Proxy(
                  Object.freeze(\#(kind == .api ? "true" : "false") ? { action, request: unavailable } : { action }),
                  {
                    get(target, name) {
                      if (name in target) return target[name];
                      throw new Error(`service installer does not provide ${String(name)}`);
                    },
                  }
                );
                const result = installer(api);
                if (result && typeof result.then === "function") throw new Error("service installer must be synchronous");
              },
            };
            """#)
            context.evaluateScript(source)
            if let syntaxError {
                throw Repository.Failure(message: "actions.js registration: \(syntaxError)")
            }
            guard let result = context.evaluateScript(
                "JSON.stringify({ installations: window.ox.__installations, actions: window.ox.__registered })"
            )?.toString(),
                  let resultData = result.data(using: .utf8),
                  let registration = try JSONSerialization.jsonObject(with: resultData) as? [String: Any],
                  registration["installations"] as? Int == 1,
                  let registered = registration["actions"] as? [String] else {
                throw Repository.Failure(message: "actions.js must install exactly once")
            }
            let declared = Set(definition.actions.map(\.id))
            let implemented = Set(registered)
            let missing = declared.subtracting(implemented).sorted()
            let extra = implemented.subtracting(declared).sorted()
            guard missing.isEmpty, extra.isEmpty else {
                let details = [
                    missing.isEmpty ? nil : "missing implementations: \(missing.joined(separator: ", "))",
                    extra.isEmpty ? nil : "undeclared implementations: \(extra.joined(separator: ", "))",
                ].compactMap { $0 }.joined(separator: "; ")
                throw Repository.Failure(message: "actions.js registration mismatch; \(details)")
            }
        case .mcp:
            let data = try await read(["service.json"])
            let manifest = try JSONDecoder().decode(MCPCatalogManifest.self, from: data)
            guard manifest.id == domain, manifest.isValid else {
                throw Repository.Failure(message: "invalid MCP manifest")
            }
        case .iOS:
            throw Repository.Failure(message: "Native iOS services cannot be edited in Local.")
        }
    }
}
