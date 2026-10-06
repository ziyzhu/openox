import Foundation
@preconcurrency import JavaScriptCore

nonisolated final class ModelPromptRenderer: @unchecked Sendable {
    static let shared = ModelPromptRenderer()

    enum Method: String {
        case responseDirective
        case websiteInstructions
    }

    private let queue = DispatchQueue(label: "ox.prompt.javascript")
    private var context: JSContext?

    func render(_ method: Method, input: JSONValue) throws -> String {
        try queue.sync {
            do {
                let context = try acquireContext()
                context.exception = nil
                let result = context.objectForKeyedSubscript("OxPrompts")?.invokeMethod(method.rawValue, withArguments: [input.toAny()])
                if let exception = context.exception { throw RuntimeError.bridge("Prompt rendering failed: \(exception.toString() ?? "unknown")") }
                guard let result, result.isString, let text = result.toString() else { throw RuntimeError.bridge("Prompt renderer returned invalid text") }
                return text
            } catch {
                Log.agent.error("PromptRenderer failed method=\(method.rawValue) error=\(error.localizedDescription)")
                throw error
            }
        }
    }

    static func defaultSoul() throws -> String {
        guard let url = Bundle.main.url(forResource: "default-soul", withExtension: "md", subdirectory: "PiDurable.bundle") else {
            throw RuntimeError.bridge("Missing default SOUL resource; run bun run build:agent before building")
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        guard !text.isEmpty else { throw RuntimeError.bridge("Default SOUL resource is empty") }
        return text
    }

    private func acquireContext() throws -> JSContext {
        if let context { return context }
        guard let url = Bundle.main.url(forResource: "prompts", withExtension: "js", subdirectory: "PiDurable.bundle") else {
            throw RuntimeError.bridge("Missing prompts.js; run bun run build:agent before building")
        }
        guard let vm = JSVirtualMachine(), let context = JSContext(virtualMachine: vm) else { throw RuntimeError.bridge("Cannot create prompt context") }
        context.evaluateScript(try String(contentsOf: url, encoding: .utf8), withSourceURL: url)
        if let exception = context.exception { throw RuntimeError.bridge("Cannot load prompt renderer: \(exception.toString() ?? "unknown")") }
        guard context.objectForKeyedSubscript("OxPrompts")?.isObject == true else { throw RuntimeError.bridge("Missing prompt renderer exports") }
        self.context = context
        Log.agent.info("PromptRenderer opened bundle=prompts.js")
        return context
    }
}
