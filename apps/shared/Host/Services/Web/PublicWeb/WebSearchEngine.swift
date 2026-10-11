import Foundation
import WebKit

nonisolated struct WebSearchError: LocalizedError, Sendable {
    nonisolated enum Kind: Sendable {
        case navigationTimedOut
        case actionTimedOut
        case unexpectedRedirect(String)
        case navigationFailed(String)
        case providerBlocked(String)
        case providerMarkupChanged
    }

    let provider: String
    let kind: Kind

    var code: String {
        switch kind {
        case .navigationTimedOut: "navigation_timed_out"
        case .actionTimedOut: "action_timed_out"
        case .unexpectedRedirect: "unexpected_redirect"
        case .navigationFailed: "navigation_failed"
        case .providerBlocked: "provider_blocked"
        case .providerMarkupChanged: "provider_markup_changed"
        }
    }

    var isRetryable: Bool {
        switch kind {
        case .navigationTimedOut, .actionTimedOut, .navigationFailed, .providerMarkupChanged: true
        case .unexpectedRedirect, .providerBlocked: false
        }
    }

    var errorDescription: String? {
        switch kind {
        case .navigationTimedOut: "ox.web.search: \(provider) navigation timed out"
        case .actionTimedOut: "ox.web.search: \(provider) search timed out"
        case .unexpectedRedirect(let host): "ox.web.search: \(provider) redirected to an unexpected host: \(host)"
        case .navigationFailed(let message): "ox.web.search: \(provider) navigation failed: \(message)"
        case .providerBlocked(let reason): "ox.web.search: \(provider) blocked the search with \(reason)"
        case .providerMarkupChanged: "ox.web.search: \(provider) returned an unrecognized results page"
        }
    }
}

nonisolated struct AggregatedWebSearchError: LocalizedError, Sendable {
    let failures: [String]

    var errorDescription: String? {
        "ox.web.search: all providers failed: \(failures.joined(separator: "; "))"
    }
}

nonisolated enum BrowserSearchAdapter: CaseIterable, Sendable {
    case brave
    case duckDuckGo
    case google

    var id: String {
        switch self {
        case .brave: "search.brave.com"
        case .duckDuckGo: "duckduckgo.com"
        case .google: "google.com"
        }
    }

    var endpoint: URL {
        switch self {
        case .brave: URL(string: "https://search.brave.com/search")!
        case .duckDuckGo: URL(string: "https://duckduckgo.com/")!
        case .google: URL(string: "https://www.google.com/search")!
        }
    }

    func queryItems(for request: WebSearchRequest) -> [URLQueryItem] {
        switch self {
        case .brave:
            [URLQueryItem(name: "q", value: request.query), URLQueryItem(name: "source", value: "web")]
        case .duckDuckGo:
            [URLQueryItem(name: "q", value: request.query), URLQueryItem(name: "ia", value: "web")]
        case .google:
            [
                URLQueryItem(name: "q", value: request.query),
                URLQueryItem(name: "num", value: "10"),
                URLQueryItem(name: "hl", value: "en"),
            ]
        }
    }

    func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        switch self {
        case .brave:
            return host == "search.brave.com"
        case .duckDuckGo:
            return host == "duckduckgo.com" || host.hasSuffix(".duckduckgo.com")
        case .google:
            return host == "google.com" || host.hasSuffix(".google.com")
        }
    }
}

@MainActor
private final class WebSearchProviderRuntime {
    private static let maximumResults = 10
    private static let maximumAttempts = 2
    private static let maximumConcurrentSearches = 4
    private static let retryDelayNanoseconds: UInt64 = 200_000_000
    private static let initialResultReadinessNanoseconds: UInt64 = 2_000_000_000
    private static let retryResultReadinessNanoseconds: UInt64 = 500_000_000

    let adapter: BrowserSearchAdapter
    var id: String { adapter.id }

    private struct ActionPage: Decodable {
        enum Status: String, Decodable {
            case results
            case empty
            case pending
        }

        struct Item: Decodable {
            let title: String
            let url: String
            let snippet: String
            let publishedAt: String?
        }

        let items: [Item]
        let status: Status
        let readyState: String
        let headingCount: Int
        let resultContainerCount: Int
    }

    private struct NavigationDecider: WebPage.NavigationDeciding {
        let onBlocked: @MainActor (String) -> Void
        let allows: @MainActor (URL) -> Bool

        mutating func decidePolicy(
            for action: WebPage.NavigationAction,
            preferences: inout WebPage.NavigationPreferences
        ) async -> WKNavigationActionPolicy {
            guard action.target?.isMainFrame != false else { return .allow }
            guard action.target != nil else { return .cancel }
            let url = action.request.url
            let allowed = if url?.scheme == "about" {
                true
            } else if let url {
                allows(url)
            } else {
                false
            }
            guard allowed else {
                onBlocked(url?.host?.lowercased() ?? "unknown")
                return .cancel
            }
            return .allow
        }
    }

    private final class SearchSession {
        var webPage: WebPage?
        var blockedHost: String?
    }

    private var activeSearches = 0
    private var searchWaiters: [CheckedContinuation<Void, Never>] = []

    private static let actionsScript = #"""
    (() => {
      const actions = new Map();
      const action = (name, definition) => actions.set(name, definition.invoke);
      const cleanText = (value) => (value || "").replace(/\s+/g, " ").trim();
      const resolvedUrl = (href, origin) => {
        if (!href) return "";
        try {
          const initial = new URL(href, origin);
          let redirected = "";
          if ((initial.hostname === "google.com" || initial.hostname.endsWith(".google.com")) && initial.pathname === "/url") {
            redirected = initial.searchParams.get("q") || "";
          }
          if ((initial.hostname === "duckduckgo.com" || initial.hostname.endsWith(".duckduckgo.com")) && initial.pathname === "/l/") {
            redirected = initial.searchParams.get("uddg") || "";
          }
          const resolved = redirected ? new URL(redirected) : initial;
          return resolved.protocol === "http:" || resolved.protocol === "https:" ? resolved.href : "";
        } catch {
          return "";
        }
      };
      const isProviderUrl = (value) => {
        try {
          const host = new URL(value).hostname;
          return host === "google.com" || host.endsWith(".google.com")
            || host === "duckduckgo.com" || host.endsWith(".duckduckgo.com")
            || host === "search.brave.com";
        } catch {
          return true;
        }
      };
      const append = (items, seen, href, title, snippet, publishedAt = null) => {
        const url = resolvedUrl(href, document.location.origin);
        const normalizedTitle = cleanText(title);
        if (!url || !normalizedTitle || isProviderUrl(url) || seen.has(url)) return;
        seen.add(url);
        items.push({ title: normalizedTitle, url, snippet: cleanText(snippet), publishedAt });
      };
      const googleContainer = (link) => link.closest("div[data-hveid]") || link.closest(".MjjYud") || link.parentElement?.parentElement?.parentElement || null;
      const parseGoogle = () => {
        const seen = new Set();
        const items = [];
        for (const heading of document.querySelectorAll("h3")) {
          const link = heading.closest("a[href]");
          if (!link) continue;
          const container = googleContainer(link);
          const known = container?.querySelector(".VwiC3b, .s3v9rd, [data-sncf]");
          let snippet = cleanText(known?.innerText);
          if (!snippet && container) {
            for (const element of container.querySelectorAll("div, span")) {
              const value = cleanText(element.innerText || element.textContent);
              if (value.length > 20 && value.length > snippet.length && value !== cleanText(heading.textContent) && !value.includes("›")) snippet = value;
            }
          }
          const seconds = Number(container?.querySelector("[data-ts]")?.getAttribute("data-ts"));
          const date = Number.isFinite(seconds) && seconds > 0 ? new Date(seconds * 1000) : null;
          append(items, seen, link.getAttribute("href"), heading.textContent, snippet, date && Number.isFinite(date.getTime()) ? date.toISOString() : null);
        }
        return items;
      };
      const parseBrave = () => {
        const seen = new Set();
        const items = [];
        for (const root of document.querySelectorAll("[data-type='web']")) {
          const titleElement = root.querySelector(".search-snippet-title");
          const link = titleElement?.closest("a[href]") || root.querySelector("a[href]");
          append(
            items,
            seen,
            link?.getAttribute("href"),
            titleElement?.getAttribute("title") || titleElement?.textContent,
            root.querySelector(".generic-snippet .content, .generic-snippet")?.textContent
          );
        }
        return items;
      };
      const parseDuckDuckGo = () => {
        const seen = new Set();
        const items = [];
        const roots = document.querySelectorAll(".result:not(.result--ad), article[data-testid='result']");
        for (const root of roots) {
          const link = root.querySelector("a.result__a[href], a[data-testid='result-title-a'][href]");
          append(
            items,
            seen,
            link?.getAttribute("href"),
            link?.textContent,
            root.querySelector(".result__snippet, [data-result='snippet']")?.textContent
          );
        }
        return items;
      };
      const isBlocked = (provider) => {
        if (provider === "google.com" && (document.location.hostname === "sorry.google.com" || document.querySelector("form#captcha-form, form[action*='/sorry/']"))) return "CAPTCHA";
        if (provider === "google.com" && (document.location.hostname === "consent.google.com" || document.querySelector("form[action*='consent.google.com']"))) return "consent";
        if (provider === "duckduckgo.com" && document.querySelector(".anomaly-modal, [data-testid='anomaly-modal']")) return "CAPTCHA";
        if (document.querySelector("form[action*='challenge'], iframe[src*='captcha'], [data-testid='captcha']")) return "CAPTCHA";
        return "";
      };
      const isExplicitlyEmpty = (provider) => {
        if (provider === "google.com") {
          const text = cleanText(document.querySelector("#topstuff")?.textContent);
          return /did not match any documents|no results found/i.test(text);
        }
        return !!document.querySelector("[data-testid='no-results-message'], .no-results, .no-results-message");
      };
      action("searchWeb", {
        async invoke({ query, provider } = {}) {
          if (!query || !provider) throw new Error("searchWeb: query and provider are required");
          const blocked = isBlocked(provider);
          if (blocked) throw new Error(blocked);
          const items = provider === "search.brave.com"
            ? parseBrave()
            : provider === "duckduckgo.com"
              ? parseDuckDuckGo()
              : parseGoogle();
          return {
            items,
            status: items.length ? "results" : isExplicitlyEmpty(provider) ? "empty" : "pending",
            readyState: document.readyState,
            headingCount: document.querySelectorAll("h2, h3").length,
            resultContainerCount: document.querySelectorAll("[data-type='web'], .result:not(.result--ad), article[data-testid='result'], .Gx5Zad:not(#st-card), .MjjYud, div[data-hveid]").length
          };
        }
      });
      window.ox = {
        callServiceAction: async (name, args) => {
          const handler = actions.get(name);
          if (!handler) throw new Error(`unknown action: ${name}`);
          return await handler(args || {});
        }
      };
    })();
    """#

    init(adapter: BrowserSearchAdapter) {
        self.adapter = adapter
    }

    func search(_ request: WebSearchRequest) async throws -> WebSearchPage {
        let queued = Date()
        await acquireSearch()
        defer { releaseSearch() }
        try Task.checkCancellation()

        let session = SearchSession()
        let correlation = String(UUID().uuidString.prefix(8))
        let started = Date()
        let queueMS = Int(started.timeIntervalSince(queued) * 1_000)
        Log.webSearch.info("search start id=\(correlation) provider=\(id) queryChars=\(request.query.count) active=\(activeSearches) queueMs=\(queueMS)")
        for attempt in 1...Self.maximumAttempts {
            do {
                let page = try await performSearch(request, session: session, correlation: correlation, attempt: attempt)
                let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
                Log.webSearch.info("search result id=\(correlation) provider=\(id) attempt=\(attempt) items=\(page.items.count) ms=\(elapsed)")
                return page
            } catch is CancellationError {
                reset(session)
                throw CancellationError()
            } catch {
                let searchError = error as? WebSearchError
                let code = searchError?.code ?? "unknown"
                let retrying = attempt < Self.maximumAttempts && searchError?.isRetryable == true
                let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
                if retrying {
                    Log.webSearch.warning("search attempt failed id=\(correlation) provider=\(id) attempt=\(attempt) code=\(code) retrying=true retryDelayMs=200 ms=\(elapsed) error=\(LogPrivacy.text(error.localizedDescription))")
                } else {
                    Log.webSearch.error("search attempt failed id=\(correlation) provider=\(id) attempt=\(attempt) code=\(code) retrying=false ms=\(elapsed) error=\(LogPrivacy.text(error.localizedDescription))")
                }
                guard retrying else { throw error }
                reset(session)
                try await Task.sleep(nanoseconds: Self.retryDelayNanoseconds)
            }
        }
        throw failure(.navigationFailed("retry loop ended unexpectedly"))
    }

    private func performSearch(
        _ request: WebSearchRequest,
        session: SearchSession,
        correlation: String,
        attempt: Int
    ) async throws -> WebSearchPage {
        let webPage = searchWebPage(session)
        let url = try searchURL(for: request)
        Log.webSearch.info("search navigate id=\(correlation) provider=\(id) attempt=\(attempt) host=\(url.host ?? "unknown") path=\(url.path)")
        let navigationEvent = try await load(URLRequest(url: url), session: session)
        guard let host = webPage.url?.host?.lowercased() else { throw failure(.providerMarkupChanged) }
        guard allows(webPage.url) else { throw failure(.unexpectedRedirect(host)) }
        Log.webSearch.info("search navigation ready id=\(correlation) provider=\(id) attempt=\(attempt) event=\(navigationEvent) host=\(host) path=\(webPage.url?.path ?? "unknown")")
        let actionPage = try await waitForSearch(query: request.query, in: webPage, correlation: correlation, attempt: attempt)
        return WebSearchPage(query: request.query, items: normalize(actionPage.items), provider: id, providers: [id])
    }

    private func searchURL(for request: WebSearchRequest) throws -> URL {
        var components = URLComponents(url: searchEndpoint, resolvingAgainstBaseURL: false)
        var queryItems = adapter.queryItems(for: request)
        #if targetEnvironment(simulator)
        if SimEnv.webSearchEndpoint != nil {
            queryItems.append(URLQueryItem(name: "provider", value: id))
        }
        #endif
        components?.queryItems = queryItems
        guard let url = components?.url else { throw failure(.navigationFailed("invalid search URL")) }
        return url
    }

    private var searchEndpoint: URL {
        #if targetEnvironment(simulator)
        if let endpoint = SimEnv.webSearchEndpoint { return endpoint }
        #endif
        return adapter.endpoint
    }

    private func allows(_ url: URL?) -> Bool {
        guard let url else { return false }
        #if targetEnvironment(simulator)
        if let endpoint = SimEnv.webSearchEndpoint {
            return url.scheme?.lowercased() == endpoint.scheme?.lowercased()
                && url.host?.lowercased() == endpoint.host?.lowercased()
                && url.port == endpoint.port
        }
        #endif
        return adapter.allows(url)
    }

    private func searchWebPage(_ session: SearchSession) -> WebPage {
        if let webPage = session.webPage { return webPage }
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultNavigationPreferences.allowsContentJavaScript = true
        configuration.defaultNavigationPreferences.preferredContentMode = .desktop
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.actionsScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        let webPage = WebPage(
            configuration: configuration,
            navigationDecider: NavigationDecider(
                onBlocked: { [weak session] host in session?.blockedHost = host },
                allows: { [weak self] url in self?.allows(url) == true }
            )
        )
        #if targetEnvironment(simulator)
        webPage.isInspectable = true
        #endif
        session.webPage = webPage
        Log.webSearch.info("search webpage created provider=\(id) store=nonpersistent")
        return webPage
    }

    private func load(_ request: URLRequest, session: SearchSession) async throws -> WebPage.NavigationEvent {
        guard let webPage = session.webPage else { throw failure(.navigationFailed("search page is unavailable")) }
        session.blockedHost = nil
        do {
            return try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: WebPage.NavigationEvent.self) { group in
                    group.addTask { @MainActor in
                        for try await event in webPage.load(request) {
                            if event == .committed || event == .finished { return event }
                        }
                        throw self.failure(.navigationFailed("navigation ended before finishing"))
                    }
                    group.addTask { @MainActor in
                        try await Task.sleep(nanoseconds: 15_000_000_000)
                        webPage.stopLoading()
                        throw self.failure(.navigationTimedOut)
                    }
                    defer { group.cancelAll() }
                    guard let event = try await group.next() else {
                        throw self.failure(.navigationFailed("navigation produced no events"))
                    }
                    return event
                }
            } onCancel: {
                Task { @MainActor [weak webPage] in webPage?.stopLoading() }
            }
        } catch {
            if error is CancellationError { throw error }
            if let blockedHost = session.blockedHost {
                throw failure(.unexpectedRedirect(blockedHost))
            }
            if let searchError = error as? WebSearchError {
                throw searchError
            }
            if case WebPage.NavigationError.failedProvisionalNavigation(let cause) = error {
                throw failure(.navigationFailed(cause.localizedDescription))
            }
            throw failure(.navigationFailed(error.localizedDescription))
        }
    }

    private func waitForSearch(
        query: String,
        in webPage: WebPage,
        correlation: String,
        attempt: Int
    ) async throws -> ActionPage {
        let readinessNanoseconds = attempt == 1
            ? Self.initialResultReadinessNanoseconds
            : Self.retryResultReadinessNanoseconds
        let deadline = Date().addingTimeInterval(Double(readinessNanoseconds) / 1_000_000_000)
        var lastPage: ActionPage?
        repeat {
            try Task.checkCancellation()
            let page = try await inspectSearch(query: query, in: webPage)
            lastPage = page
            if page.status != .pending {
                Log.webSearch.info("search page classified id=\(correlation) provider=\(id) attempt=\(attempt) status=\(page.status.rawValue) readyState=\(page.readyState) headings=\(page.headingCount) containers=\(page.resultContainerCount) parsed=\(page.items.count)")
                return page
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        } while Date() < deadline
        if let lastPage {
            Log.webSearch.warning("search page unrecognized id=\(correlation) provider=\(id) attempt=\(attempt) readyState=\(lastPage.readyState) headings=\(lastPage.headingCount) containers=\(lastPage.resultContainerCount) parsed=\(lastPage.items.count)")
        }
        throw failure(.providerMarkupChanged)
    }

    private func inspectSearch(query: String, in webPage: WebPage) async throws -> ActionPage {
        let raw = try await withThrowingTaskGroup(of: Any?.self) { group in
            group.addTask { @MainActor in
                do {
                    return try await webPage.callJavaScript(
                        "return window.ox?.callServiceAction ? JSON.stringify(await window.ox.callServiceAction('searchWeb', { query, provider })) : null;",
                        arguments: ["query": query, "provider": self.id],
                        in: nil,
                        contentWorld: .page
                    )
                } catch {
                    let nsError = error as NSError
                    let message = (nsError.userInfo["WKJavaScriptExceptionMessage"] as? String)
                        ?? (nsError.userInfo[NSLocalizedDescriptionKey] as? String)
                        ?? error.localizedDescription
                    if message.localizedCaseInsensitiveContains("CAPTCHA") {
                        throw self.failure(.providerBlocked("CAPTCHA"))
                    }
                    if message.localizedCaseInsensitiveContains("consent") {
                        throw self.failure(.providerBlocked("consent"))
                    }
                    throw self.failure(.navigationFailed(message))
                }
            }
            group.addTask { @MainActor in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw self.failure(.actionTimedOut)
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard raw != nil else {
            return ActionPage(items: [], status: .pending, readyState: "loading", headingCount: 0, resultContainerCount: 0)
        }
        guard let text = raw as? String, let data = text.data(using: .utf8),
              let page = try? JSONDecoder().decode(ActionPage.self, from: data) else {
            throw failure(.providerMarkupChanged)
        }
        return page
    }

    private func normalize(_ raw: [ActionPage.Item]) -> [WebSearchResult] {
        var seen = Set<String>()
        var results: [WebSearchResult] = []
        for item in raw {
            guard let normalized = normalizedURL(item.url), let host = normalized.host?.lowercased() else { continue }
            let value = normalized.absoluteString
            guard seen.insert(value).inserted else { continue }
            let title = clipped(item.title.trimmingCharacters(in: .whitespacesAndNewlines), limit: 300)
            guard !title.isEmpty else { continue }
            results.append(WebSearchResult(
                id: "search-\(results.count + 1)",
                title: title,
                url: value,
                snippet: clipped(item.snippet.trimmingCharacters(in: .whitespacesAndNewlines), limit: 1_000),
                site: host,
                publishedAt: item.publishedAt,
                providers: [id]
            ))
            if results.count == Self.maximumResults { break }
        }
        return results
    }

    private func normalizedURL(_ value: String) -> URL? {
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host != nil else { return nil }
        components.scheme = scheme
        components.host = components.host?.lowercased()
        components.fragment = nil
        let tracking = Set(["fbclid", "gclid", "utm_campaign", "utm_content", "utm_medium", "utm_source", "utm_term"])
        components.queryItems = components.queryItems?.filter { !tracking.contains($0.name.lowercased()) }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url
    }

    private func clipped(_ value: String, limit: Int) -> String {
        value.count <= limit ? value : String(value.prefix(limit))
    }

    private func failure(_ kind: WebSearchError.Kind) -> WebSearchError {
        WebSearchError(provider: id, kind: kind)
    }

    private func reset(_ session: SearchSession) {
        session.webPage?.stopLoading()
        session.webPage = nil
        session.blockedHost = nil
    }

    private func acquireSearch() async {
        guard activeSearches >= Self.maximumConcurrentSearches else {
            activeSearches += 1
            return
        }
        await withCheckedContinuation { searchWaiters.append($0) }
    }

    private func releaseSearch() {
        guard !searchWaiters.isEmpty else {
            activeSearches -= 1
            return
        }
        searchWaiters.removeFirst().resume()
    }
}

@MainActor
final class WebSearchEngine {
    static let shared = WebSearchEngine(
        providers: BrowserSearchAdapter.allCases.map { WebSearchProviderRuntime(adapter: $0) }
    )
    private static let maximumResults = 10

    let id = "metasearch"
    private let providers: [WebSearchProviderRuntime]

    private struct Outcome: Sendable {
        let index: Int
        let page: WebSearchPage?
        let failure: String?
    }

    private struct Candidate {
        var result: WebSearchResult
        var score: Double
        let firstProvider: Int
        let firstRank: Int
    }

    private init(providers: [WebSearchProviderRuntime]) {
        self.providers = providers
    }

    func search(_ request: WebSearchRequest) async throws -> WebSearchPage {
        let started = Date()
        let outcomes = await withTaskGroup(of: Outcome.self, returning: [Outcome].self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask { @MainActor in
                    do {
                        return Outcome(index: index, page: try await provider.search(request), failure: nil)
                    } catch {
                        return Outcome(index: index, page: nil, failure: error.localizedDescription)
                    }
                }
            }
            var values: [Outcome] = []
            for await outcome in group {
                values.append(outcome)
            }
            return values.sorted { $0.index < $1.index }
        }
        try Task.checkCancellation()
        let pages = outcomes.compactMap(\.page)
        guard !pages.isEmpty else {
            throw AggregatedWebSearchError(failures: outcomes.compactMap(\.failure))
        }
        let failures = outcomes.compactMap(\.failure)
        let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
        if failures.isEmpty {
            Log.webSearch.info("aggregate result providers=\(pages.count) items=\(pages.reduce(0) { $0 + $1.items.count }) ms=\(elapsed)")
        } else {
            Log.webSearch.warning("aggregate partial providers=\(pages.count) failures=\(failures.count) ms=\(elapsed) errors=\(LogPrivacy.text(failures.joined(separator: "; ")))")
        }
        return merge(request: request, pages: pages)
    }

    private func merge(request: WebSearchRequest, pages: [WebSearchPage]) -> WebSearchPage {
        var candidates: [String: Candidate] = [:]
        for (providerIndex, page) in pages.enumerated() {
            for (offset, item) in page.items.enumerated() {
                let rank = offset + 1
                let score = 1.0 / Double(60 + rank)
                let key = canonicalKey(item.url)
                if var existing = candidates[key] {
                    var providerIDs = existing.result.providers
                    for provider in item.providers where !providerIDs.contains(provider) {
                        providerIDs.append(provider)
                    }
                    existing.result = WebSearchResult(
                        id: existing.result.id,
                        title: item.title.count > existing.result.title.count ? item.title : existing.result.title,
                        url: existing.result.url,
                        snippet: item.snippet.count > existing.result.snippet.count ? item.snippet : existing.result.snippet,
                        site: existing.result.site,
                        publishedAt: existing.result.publishedAt ?? item.publishedAt,
                        providers: providerIDs
                    )
                    existing.score += score
                    candidates[key] = existing
                } else {
                    candidates[key] = Candidate(result: item, score: score, firstProvider: providerIndex, firstRank: rank)
                }
            }
        }
        let ordered = candidates.values.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.result.providers.count != $1.result.providers.count { return $0.result.providers.count > $1.result.providers.count }
            if $0.firstRank != $1.firstRank { return $0.firstRank < $1.firstRank }
            if $0.firstProvider != $1.firstProvider { return $0.firstProvider < $1.firstProvider }
            return $0.result.url < $1.result.url
        }
        let items = ordered.prefix(Self.maximumResults).enumerated().map { index, candidate in
            WebSearchResult(
                id: "search-\(index + 1)",
                title: candidate.result.title,
                url: candidate.result.url,
                snippet: candidate.result.snippet,
                site: candidate.result.site,
                publishedAt: candidate.result.publishedAt,
                providers: candidate.result.providers
            )
        }
        let providerIDs = pages.flatMap(\.providers).reduce(into: [String]()) { values, provider in
            if !values.contains(provider) { values.append(provider) }
        }
        return WebSearchPage(
            query: request.query,
            items: items,
            provider: providerIDs.count == 1 ? providerIDs[0] : id,
            providers: providerIDs
        )
    }

    private func canonicalKey(_ value: String) -> String {
        guard let components = URLComponents(string: value), let host = components.host?.lowercased() else { return value }
        let port = components.port.map { ":\($0)" } ?? ""
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        return "\(host)\(port)\(path)\(query)"
    }
}
