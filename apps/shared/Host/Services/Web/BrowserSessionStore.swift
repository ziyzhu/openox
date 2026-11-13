import Foundation
import WebKit

@MainActor
final class BrowserSessionStore {
    enum Purpose: Equatable {
        case session(String?)
        case inspector(UUID)
        case debug(UUID)
        case browser(UUID)
        case model(UUID)
        case conversation(UUID)

        var logLabel: String {
            switch self {
            case .session: "session"
            case .inspector: "inspector"
            case .debug: "debug"
            case .browser: "browser"
            case .model: "model"
            case .conversation: "conversation"
            }
        }
    }

    struct Registration {
        let page: BrowserSession
        let owner: Purpose
    }

    private struct Entry {
        let domain: String
        let owned: Registration
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    var sessions: [BrowserSession] { entries.values.map { $0.owned.page } }

    func pages(for domain: String) -> [ObjectIdentifier: Registration] {
        entries.filter { $0.value.domain == domain }.mapValues(\.owned)
    }

    func contains(_ page: BrowserSession) -> Bool {
        entries[ObjectIdentifier(page)] != nil && page.isOpen
    }

    func register(_ page: BrowserSession, domain: String, owner: Purpose) {
        entries[ObjectIdentifier(page)] = Entry(domain: domain, owned: Registration(page: page, owner: owner))
    }

    func reusablePage(for service: Service, scopeID: UUID) -> BrowserSession? {
        let matches = entries.values.filter { entry in
            guard case .session = entry.owned.owner, entry.domain != service.domain else { return false }
            let page = entry.owned.page
            return page.scopeID == scopeID && page.isReady && page.secretAttempt == nil
                && page.page.url?.host.map(service.isServiceHost) == true
        }
        guard matches.count == 1 else { return nil }
        return matches.first?.owned.page
    }

    func sessionPage(for action: Service.Action) -> BrowserSession? {
        let candidates = pages(for: action.service.domain).values.filter {
            guard $0.page.scopeID == action.scopeID else { return false }
            if case .session = $0.owner { return true }
            return false
        }
        if let id = action.session?.objectValue?["id"]?.stringValue {
            return candidates.first { $0.owner == .session(id) }?.page
                ?? candidates.first { $0.owner == .session(nil) }?.page
        }
        return candidates.first { $0.owner == .session(nil) }?.page
            ?? candidates.max {
                ($0.page.lastInvocation?.startedAt ?? .distantPast) < ($1.page.lastInvocation?.startedAt ?? .distantPast)
            }?.page
    }

    func updateSessionPage(_ page: BrowserSession, domain: String, session: JSONValue?) {
        let candidates = pages(for: domain)
        guard let current = candidates[ObjectIdentifier(page)], case .session = current.owner else { return }
        let owner = Purpose.session(session?.objectValue?["id"]?.stringValue)
        guard current.owner != owner else { return }
        guard !candidates.values.contains(where: { $0.owner == owner && $0.page !== page && $0.page.scopeID == page.scopeID }) else {
            Log.webView.warning("BrowserSession.account conflict domain=\(domain) session=\(page.logLabel)")
            return
        }
        register(page, domain: domain, owner: owner)
    }

    func open(for action: Service.Action, purpose: Purpose) async throws -> BrowserSession {
        let page: BrowserSession
        if case .session = purpose, let existing = sessionPage(for: action) {
            if existing.openingTask == nil {
                try Task.checkCancellation()
                return existing
            }
            page = existing
        } else {
            page = BrowserSession(manager: action.service.manager)
            page.scopeID = action.scopeID
            if action.service.isWebService { page.frameServiceSources[action.service.domain] = action.scripts }
            register(page, domain: action.service.domain, owner: purpose)
            page.openingTask = Task { @MainActor [weak page] in
                guard let page else { return false }
                page.configureScripts(for: action.baseURL, in: page)
                page.navigationTask = page.observeNavigations(in: page)
                let landed = await page.navigate(action.baseURL, in: page)
                guard landed != nil, page.isOpen, page.isReady else { return false }
                page.executionURL = action.baseURL
                return true
            }
            Log.webView.info("BrowserSession.open purpose=\(purpose.logLabel) service=\(action.service.domain) session=\(page.logLabel) resident=\(entries.count)")
        }
        let loaded = await page.openingTask?.value ?? page.isReady
        page.openingTask = nil
        guard loaded, contains(page), page.isReady else {
            let error = page.navigationFailure.map(Service.EvalError.navigationFailed) ?? .notReady
            close(page, error: error)
            throw error
        }
        try Task.checkCancellation()
        return page
    }

    func close(_ page: BrowserSession, error: any Error = CancellationError()) {
        guard let entry = entries.removeValue(forKey: ObjectIdentifier(page)) else { return }
        for service in page.manager.services { service.conversationHandoffs[page.id]?.session.cancel() }
        page.close(error: error)
        Log.webView.info("BrowserSession.close purpose=\(entry.owned.owner.logLabel) session=\(page.logLabel) resident=\(entries.count)")
    }

    private func sessions(using domain: String) -> [BrowserSession] {
        entries.values.filter { $0.domain == domain || $0.owned.page.frameServiceSources[domain] != nil }.map { $0.owned.page }
    }

    func close(using domain: String, error: any Error) {
        for page in sessions(using: domain) { close(page, error: error) }
    }

    func closeWhenIdle(using domain: String, error: any Error) async {
        let pages = sessions(using: domain)
        guard !pages.isEmpty else { return }
        await withCheckedContinuation { continuation in
            var remaining = pages.count
            for page in pages {
                page.manager.actionScheduler.closeWhenIdle(page, error: error) {
                    self.close(page, error: error)
                    remaining -= 1
                    if remaining == 0 { continuation.resume() }
                }
            }
        }
    }

    func close(scopeID: UUID) {
        for page in sessions where page.scopeID == scopeID { close(page) }
    }

    func releaseIdlePages(reason: String) {
        let idle = entries.values.filter {
            guard case .session = $0.owned.owner else { return false }
            let page = $0.owned.page
            return page.openingTask == nil && page.navigationPhase.load == nil && page.manager.actionScheduler.isIdle(page)
        }.map { $0.owned.page }
        for page in idle { close(page) }
        if !idle.isEmpty { Log.webView.info("BrowserSession.release reason=\(reason) count=\(idle.count)") }
    }
}
