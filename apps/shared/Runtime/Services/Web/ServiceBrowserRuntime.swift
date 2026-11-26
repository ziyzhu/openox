import Foundation
import WebKit

extension Service {
    @discardableResult
    func navigate(_ url: URL, timeout: TimeInterval = 15) async -> URL? {
        guard let action = await inspectionAction() else { return nil }
        return try? await withNavigationPage(for: action) { page in
            await self.navigate(url, in: page, timeout: timeout)
        }
    }

    @discardableResult
    func reload(timeout: TimeInterval = 15) async -> URL? {
        guard let action = await inspectionAction() else { return nil }
        return try? await withNavigationPage(for: action) { page in
            await self.reload(page, timeout: timeout)
        }
    }

    @discardableResult
    func goBack(timeout: TimeInterval = 15) async -> URL? {
        guard let action = await inspectionAction() else { return nil }
        return try? await withNavigationPage(for: action) { page in
            await self.goBack(page, timeout: timeout)
        }
    }

    @discardableResult
    func goForward(timeout: TimeInterval = 15) async -> URL? {
        guard let action = await inspectionAction() else { return nil }
        return try? await withNavigationPage(for: action) { page in
            await self.goForward(page, timeout: timeout)
        }
    }

    private func withNavigationPage<T>(
        for action: Action,
        operation: @escaping @MainActor @Sendable (BrowserSession) async throws -> T
    ) async throws -> T {
        guard domain != "ios:browser" else { throw EvalError.notActive }
        let page = try await openSessionPage(for: action)
        return try await manager.actionScheduler.schedule(
            action,
            on: page,
            kind: .navigation,
            operation: operation
        )
    }

    func navigate(_ url: URL, in page: BrowserSession, timeout: TimeInterval = 15) async -> URL? {
        await page.navigate(url, in: page, timeout: timeout)
    }

    func reload(_ page: BrowserSession, fromOrigin: Bool = false, timeout: TimeInterval = 15) async -> URL? {
        await page.reload(page, fromOrigin: fromOrigin, timeout: timeout)
    }

    func goBack(_ page: BrowserSession, timeout: TimeInterval = 15) async -> URL? {
        await page.goBack(page, timeout: timeout)
    }

    func goForward(_ page: BrowserSession, timeout: TimeInterval = 15) async -> URL? {
        await page.goForward(page, timeout: timeout)
    }

    func performNavigation(_ command: NavigationCommand, in page: BrowserSession, label: String, timeout: TimeInterval, prepare: (@MainActor () async -> Void)? = nil) async -> URL? {
        await page.performNavigation(command, in: page, label: label, timeout: timeout, prepare: prepare)
    }

    func abandonActiveNavigation(in page: BrowserSession, reason: String) {
        page.abandonActiveNavigation(in: page, reason: reason)
    }

    @discardableResult
    func transitionNavigation(_ event: BrowserSession.NavigationEvent, on page: BrowserSession) -> Bool {
        page.transitionNavigation(event, on: page)
    }

    func activeInvocationCount(in page: BrowserSession) -> Int {
        manager.actionScheduler.activeInvocationCount(on: page)
    }

    func queuedInvocationCount(in page: BrowserSession) -> Int {
        manager.actionScheduler.queuedInvocationCount(on: page)
    }

    func advancePage(_ page: BrowserSession) {
        page.advancePage(page)
    }

    func failQueuedInvocations(in page: BrowserSession, error: any Error) {
        manager.actionScheduler.failPending(on: page, error: error)
    }

    func evalOnce(_ page: BrowserSession, _ source: String, timeout: TimeInterval, frame: WebPage.FrameInfo? = nil) async throws -> Any? {
        try await page.evalOnce(page, source, timeout: timeout, frame: frame)
    }

    func evalAsync(_ page: BrowserSession, _ source: String, context: String, timeout: TimeInterval = 30) async throws -> Any? {
        try await page.evalAsync(page, source, context: context, timeout: timeout)
    }

    func configureScripts(for url: URL?, in page: BrowserSession) {
        page.configureScripts(for: url, in: page)
    }

    func installFrameServices(_ services: [Service], on page: BrowserSession) async throws {
        try await page.installFrameServices(services, on: page)
    }
}
