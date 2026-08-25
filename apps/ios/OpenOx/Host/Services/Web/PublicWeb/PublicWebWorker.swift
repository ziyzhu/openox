import Foundation
import WebKit

nonisolated enum PublicWebWorkerError: LocalizedError, Sendable {
    case missingBundle
    case initializationFailed
    case extractionTimedOut
    case invalidResult

    var errorDescription: String? {
        switch self {
        case .missingBundle: "ox.web.fetch: HTML extractor bundle is unavailable"
        case .initializationFailed: "ox.web.fetch: HTML extractor failed to initialize"
        case .extractionTimedOut: "ox.web.fetch: HTML extraction timed out"
        case .invalidResult: "ox.web.fetch: HTML extractor returned an invalid result"
        }
    }
}

nonisolated struct PublicWebExtraction: Decodable, Sendable {
    let markdown: String
    let title: String
    let author: String
    let description: String
    let published: String
    let site: String
    let wordCount: Int
}

@MainActor
final class PublicWebWorker {
    static let shared = PublicWebWorker()

    private enum State {
        case cold
        case warm(WebPage)
    }

    private struct NavigationDecider: WebPage.NavigationDeciding {
        mutating func decidePolicy(
            for action: WebPage.NavigationAction,
            preferences: inout WebPage.NavigationPreferences
        ) async -> WKNavigationActionPolicy {
            guard action.target?.isMainFrame != false,
                  action.request.url?.scheme?.lowercased() == "about" else { return .cancel }
            return .allow
        }
    }

    private var state = State.cold
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func extract(html: String, url: URL) async throws -> PublicWebExtraction {
        await acquire()
        defer { release() }
        try Task.checkCancellation()

        do {
            return try await extractOnce(html: html, url: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            state = .cold
            Log.webFetch.warning("worker extraction retry url=\(LogPrivacy.url(url.absoluteString)) error=\(LogPrivacy.text(error.localizedDescription))")
            return try await extractOnce(html: html, url: url)
        }
    }

    private func extractOnce(html: String, url: URL) async throws -> PublicWebExtraction {
        let page = try await page()
        let started = Date()
        let raw = try await withThrowingTaskGroup(of: Any?.self) { group in
            group.addTask { @MainActor in
                try await page.callJavaScript(
                    "return JSON.stringify(window.oxPublicWeb.extract(html, url));",
                    arguments: ["html": html, "url": url.absoluteString],
                    in: nil,
                    contentWorld: .page
                )
            }
            group.addTask { @MainActor in
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw PublicWebWorkerError.extractionTimedOut
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        guard let json = raw as? String,
              let data = json.data(using: .utf8),
              let extraction = try? JSONDecoder().decode(PublicWebExtraction.self, from: data) else {
            throw PublicWebWorkerError.invalidResult
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
        Log.webFetch.info("worker extraction result url=\(LogPrivacy.url(url.absoluteString)) htmlChars=\(html.count) markdownChars=\(extraction.markdown.count) words=\(extraction.wordCount) ms=\(elapsed)")
        return extraction
    }

    private func page() async throws -> WebPage {
        if case .warm(let page) = state { return page }
        guard let bundleURL = Bundle.main.url(forResource: "PublicWebWorker", withExtension: "js"),
              let source = try? String(contentsOf: bundleURL, encoding: .utf8) else {
            throw PublicWebWorkerError.missingBundle
        }

        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.loadsSubresources = false
        configuration.defaultNavigationPreferences.allowsContentJavaScript = true
        configuration.userContentController.addUserScript(WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        let page = WebPage(configuration: configuration, navigationDecider: NavigationDecider())
        #if targetEnvironment(simulator)
        page.isInspectable = true
        #endif
        try await load(page)
        let ready = try await page.callJavaScript(
            "return window.oxPublicWeb?.version === 1 && typeof window.oxPublicWeb?.extract === 'function';",
            in: nil,
            contentWorld: .page
        )
        guard ready as? Bool == true else { throw PublicWebWorkerError.initializationFailed }
        state = .warm(page)
        Log.webFetch.info("worker ready store=nonpersistent subresources=false")
        return page
    }

    private func load(_ page: WebPage) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for try await event in page.load(html: "<!doctype html><html><body></body></html>") {
                    if event == .finished { return }
                }
                throw PublicWebWorkerError.initializationFailed
            }
            group.addTask { @MainActor in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                page.stopLoading()
                throw PublicWebWorkerError.initializationFailed
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        guard !waiters.isEmpty else {
            busy = false
            return
        }
        waiters.removeFirst().resume()
    }
}
