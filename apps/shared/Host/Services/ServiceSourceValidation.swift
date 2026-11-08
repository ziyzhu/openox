import Foundation
@preconcurrency import JavaScriptCore

nonisolated final class ServiceSourceValidation: @unchecked Sendable {
    private static let shared = ServiceSourceValidation()
    private static let source = Bundle.main.url(forResource: "service-validation", withExtension: "js", subdirectory: "PiDurable.bundle")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    private let queue = DispatchQueue(label: "ox.service.validation")
    private var manifestContext: JSContext?

    static func validateManifest(_ manifest: JSONValue) throws {
        try shared.queue.sync {
            let context: JSContext
            if let cached = shared.manifestContext {
                context = cached
            } else {
                context = try makeContext()
                shared.manifestContext = context
            }
            try validate("validateManifest", arguments: [manifest.toAny()], context: context)
        }
    }

    static func validateInstaller(_ source: String, manifest: JSONValue) throws {
        try validate("inspectInstaller", arguments: [source, manifest.toAny()], context: makeContext())
    }

    private static func makeContext() throws -> JSContext {
        guard let source = source, let context = JSContext() else {
            throw RuntimeError.bridge("Missing service-validation.js; run bun run build:agent before building")
        }
        context.evaluateScript(source)
        guard context.exception == nil,
              context.objectForKeyedSubscript("OxServiceValidation")?.isObject == true else {
            throw RuntimeError.bridge("Cannot load service validator")
        }
        return context
    }

    private static func validate(_ method: String, arguments: [Any], context: JSContext) throws {
        context.exception = nil
        let result = context.objectForKeyedSubscript("OxServiceValidation")?.invokeMethod(method, withArguments: arguments)
        if let exception = context.exception {
            Log.service.error("ServiceSourceValidation failed method=\(method)")
            throw RuntimeError.bridge("Service validation failed: \(exception.toString() ?? "unknown")")
        }
        guard let errors = result?.toArray() as? [String] else {
            throw RuntimeError.bridge("Service validator returned invalid errors")
        }
        guard errors.isEmpty else {
            Log.service.info("ServiceSourceValidation rejected method=\(method) errors=\(errors.count)")
            throw ServiceDefinition.ValidationError.invalid(errors.joined(separator: "; "))
        }
    }
}
