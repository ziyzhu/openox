import Foundation
import JavaScriptCore

nonisolated enum DefuddleError: LocalizedError, Sendable {
    case unavailable
    case documentTooLarge
    case extractionFailed
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .unavailable: "ox.web.fetch: HTML extractor is unavailable"
        case .documentTooLarge: "ox.web.fetch: HTML document exceeded the 10 MiB limit"
        case .extractionFailed: "ox.web.fetch: HTML extraction failed or exceeded complexity limits"
        case .emptyContent: "ox.web.fetch: HTML document has no readable content"
        }
    }
}

nonisolated enum Defuddle {
    private static let queue = DispatchQueue(label: "ai.oxcraft.web-extraction", qos: .userInitiated)
    private static let source = Bundle.main.url(forResource: "PiDurable", withExtension: "bundle")
        .flatMap { try? String(contentsOf: $0.appendingPathComponent("web-extraction.js"), encoding: .utf8) }

    static func markdown(html: String, baseURL: URL) async throws -> String {
        try Task.checkCancellation()
        guard html.utf8.count <= WebFetchClient.maximumBytes else { throw DefuddleError.documentTooLarge }
        let result: String = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    try autoreleasepool { try convert(html: html, baseURL: baseURL) }
                })
            }
        }
        try Task.checkCancellation()
        return result
    }

    private static func convert(html: String, baseURL: URL) throws -> String {
        guard let source, let context = JSContext() else { throw DefuddleError.unavailable }
        context.evaluateScript("""
            globalThis.setTimeout = globalThis.setInterval = () => { throw new Error('Timers unavailable during HTML extraction'); };
            globalThis.clearTimeout = globalThis.clearInterval = () => {};
            globalThis.atob = value => Array.from(Uint8Array.fromBase64(value), byte => String.fromCharCode(byte)).join('');
            globalThis.console = { log() {}, warn() {}, error() {}, debug() {}, info() {} };
            """)
        context.evaluateScript(source)
        guard context.exception == nil,
              let runtime = context.objectForKeyedSubscript("OxWebExtraction"), !runtime.isUndefined else {
            throw DefuddleError.unavailable
        }
        let result = runtime.invokeMethod("extract", withArguments: [html, baseURL.absoluteString])
        guard context.exception == nil, let result,
              result.forProperty("settled")?.toBool() == true,
              result.forProperty("error")?.toString() == "",
              let content = result.forProperty("content"), content.isString,
              let markdown = content.toString() else { throw DefuddleError.extractionFailed }
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DefuddleError.emptyContent }
        return markdown
    }
}
