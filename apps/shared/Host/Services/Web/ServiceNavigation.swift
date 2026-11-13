import Foundation
import WebKit

extension BrowserSession {
    func observeNavigations(in session: BrowserSession) -> Task<Void, Never> {
        Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            while !Task.isCancelled, self.owns(session) {
                do {
                    for try await event in session.page.navigations {
                        guard !Task.isCancelled else { return }
                        switch event {
                        case .startedProvisionalNavigation:
                            await self.receive(.started, from: session)
                        case .receivedServerRedirect:
                            await self.receive(.redirected, from: session)
                        case .committed:
                            await self.receive(.committed, from: session)
                        case .finished:
                            guard let url = session.page.url else { continue }
                            await self.receive(.finished(url), from: session)
                        @unknown default:
                            continue
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    if WebPage.NavigationError.isCancellation(error) {
                        Log.webView.info("Service.navigation cancelled domain=\(domain) session=\(session.logLabel)")
                        continue
                    }
                    if case WebPage.NavigationError.webContentProcessTerminated = error {
                        await self.receive(.webContentProcessTerminated, from: session)
                    } else if case WebPage.NavigationError.failedProvisionalNavigation(let cause) = error {
                        await self.receive(.failed(cause), from: session)
                    } else {
                        await self.receive(.failed(error), from: session)
                    }
                }
            }
        }
    }

    func navigate(_ url: URL, in page: BrowserSession, timeout: TimeInterval = 15) async -> URL? {
        await performNavigation(.load(URLRequest(url: url)), in: page, label: "load", timeout: timeout)
    }

    func reload(_ page: BrowserSession, fromOrigin: Bool = false, timeout: TimeInterval = 15) async -> URL? {
        await performNavigation(.reload(fromOrigin: fromOrigin), in: page, label: "reload", timeout: timeout)
    }

    func goBack(_ page: BrowserSession, timeout: TimeInterval = 15) async -> URL? {
        await performNavigation(.back, in: page, label: "back", timeout: timeout)
    }

    func goForward(_ page: BrowserSession, timeout: TimeInterval = 15) async -> URL? {
        await performNavigation(.forward, in: page, label: "forward", timeout: timeout)
    }

    func performNavigation(
        _ command: NavigationCommand,
        in session: BrowserSession,
        label: String,
        timeout: TimeInterval,
        prepare: (@MainActor () async -> Void)? = nil
    ) async -> URL? {
        guard let lease = requestNavigation(in: session, label: label, timeout: timeout) else { return nil }
        return await withTaskCancellationHandler {
            guard await awaitNavigationReservation(lease, in: session) else { return nil }
            if Task.isCancelled {
                abandonNavigation(lease, in: session, reason: "cancelled")
                return nil
            }
            if let prepare { await prepare() }
            guard !Task.isCancelled else {
                abandonNavigation(lease, in: session, reason: "cancelled")
                return nil
            }
            return await startNavigation(command, lease: lease, in: session)
        } onCancel: {
            Task { @MainActor [weak self, weak session, weak lease] in
                guard let self, let session, let lease else { return }
                self.abandonNavigation(lease, in: session, reason: "cancelled")
            }
        }
    }

    func requestNavigation(
        in session: BrowserSession,
        label: String,
        timeout: TimeInterval
    ) -> BrowserSession.NavigationLease? {
        guard owns(session) else { return nil }
        let lease = BrowserSession.NavigationLease(label: label, timeout: timeout)
        if transitionNavigation(.requested(lease), on: session) {
            session.navigationFailure = nil
            Log.webView.info("Service.navigation requested domain=\(domain) session=\(session.logLabel) id=\(lease.id.uuidString.prefix(8)) label=\(label) active=\(activeInvocationCount(in: session)) queued=\(queuedInvocationCount(in: session))")
            advancePage(session)
            return lease
        } else {
            session.navigationFailure = "Browser was busy with another navigation"
            Log.webView.info("Service.navigation rejected-busy domain=\(domain) session=\(session.logLabel) label=\(label) phase=\(session.navigationPhase.logLabel)")
            return nil
        }
    }

    func awaitNavigationReservation(
        _ lease: BrowserSession.NavigationLease,
        in session: BrowserSession
    ) async -> Bool {
        guard owns(session) else { return false }
        if case .reserved(let current) = session.navigationPhase, current === lease { return true }
        guard case .pending(let current) = session.navigationPhase, current === lease else { return false }
        return await withCheckedContinuation { continuation in
            lease.reservation = continuation
        }
    }

    func startNavigation(
        _ command: NavigationCommand,
        lease: BrowserSession.NavigationLease,
        in session: BrowserSession
    ) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            guard owns(session),
                  case .reserved(let current) = session.navigationPhase,
                  current === lease else {
                continuation.resume(returning: nil)
                return
            }
            lease.completion = continuation
            let load = BrowserSession.NavigationLoad(
                lease: lease,
                generation: session.navigationGeneration
            )
            guard transitionNavigation(.loadStarted(load), on: session) else {
                continuation.resume(returning: nil)
                return
            }
            switch command {
            case .load(let request):
                session.page.load(request)
            case .reload(let fromOrigin):
                session.page.reload(fromOrigin: fromOrigin)
            case .back:
                guard let item = session.page.backForwardList.backList.last else {
                    transitionNavigation(.startFailed(lease), on: session)
                    return
                }
                session.page.load(item)
            case .forward:
                guard let item = session.page.backForwardList.forwardList.first else {
                    transitionNavigation(.startFailed(lease), on: session)
                    return
                }
                session.page.load(item)
            }
            Log.webView.info("Service.navigation start domain=\(domain) session=\(session.logLabel) id=\(lease.id.uuidString.prefix(8)) label=\(lease.label) nav=\(session.navigationGeneration)/\(session.finishedNavigationGeneration)")
            let timeout = lease.timeout
            lease.timeoutTask = Task { @MainActor [weak self, weak session, weak lease] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled, let self, let session, let lease else { return }
                await self.navigationTimedOut(lease, in: session)
            }
        }
    }

    func abandonNavigation(
        _ lease: BrowserSession.NavigationLease,
        in session: BrowserSession,
        reason: String
    ) {
        guard owns(session) else { return }
        guard transitionNavigation(.abandoned(lease, reason), on: session) else { return }
        Log.webView.info("Service.navigation abandoned domain=\(domain) session=\(session.logLabel) id=\(lease.id.uuidString.prefix(8)) label=\(lease.label) reason=\(reason)")
    }

    func abandonActiveNavigation(in session: BrowserSession, reason: String) {
        let lease: BrowserSession.NavigationLease? = switch session.navigationPhase {
        case .pending(let current), .reserved(let current): current
        case .navigating(let load), .verifying(let load, _): load.lease
        case .settling(let settlement): settlement.load.lease
        case .ready, .unavailable: nil
        }
        guard let lease else { return }
        abandonNavigation(lease, in: session, reason: reason)
    }

    func navigationTimedOut(
        _ lease: BrowserSession.NavigationLease,
        in session: BrowserSession
    ) async {
        guard owns(session),
              session.navigationPhase.load?.lease === lease else { return }
        if case .navigating(let load) = session.navigationPhase,
           load.committed, let url = session.page.url {
            let raw = try? await evalOnce(session, "return document.readyState;", timeout: 1)
            guard !Task.isCancelled, owns(session),
                  session.navigationPhase.load?.lease === lease else { return }
            let document = raw as? String
            if case .navigating(let current) = session.navigationPhase,
               current === load, session.page.url == url,
               document == "interactive" || document == "complete" {
                guard transitionNavigation(.documentReady(load, url), on: session) else { return }
                Log.webView.info("Service.navigation document-ready domain=\(domain) session=\(session.logLabel) nav=\(load.generation) document=\(document ?? "unknown") loading=\(session.page.isLoading) seconds=\(Int(lease.timeout))")
                await verifyNavigation(in: session, load: load, url: url)
                return
            }
        }
        let phase = session.navigationPhase.logLabel
        let committed = session.navigationPhase.load?.committed ?? false
        session.navigationFailure = session.navigationFailure ?? "navigation timed out after \(Int(lease.timeout)) seconds"
        transitionNavigation(.timedOut(lease), on: session)
        Log.webView.error("Service.navigation timeout domain=\(domain) session=\(session.logLabel) id=\(lease.id.uuidString.prefix(8)) label=\(lease.label) seconds=\(Int(lease.timeout)) phase=\(phase) committed=\(committed)")
    }

    func verifyNavigation(
        in session: BrowserSession,
        load: BrowserSession.NavigationLoad,
        url: URL
    ) async {
        guard BrowserNavigation.allowsServiceNavigation(url) else {
            _ = transitionNavigation(.verified(load, url, .dispatcherMissing), on: session)
            return
        }
        guard transitionNavigation(.verified(load, url, .ready), on: session) else { return }
        Log.webView.info("BrowserSession.navigation ready session=\(session.logLabel) nav=\(load.generation) host=\(url.host ?? "?")")
    }

    func scheduleNavigationSettlement(
        in session: BrowserSession,
        settlement: BrowserSession.NavigationSettlement
    ) {
        settlement.task = Task { @MainActor [weak self, weak session, weak settlement] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, let session, let settlement else { return }
            await self.receive(.settled(settlement), from: session)
        }
    }

    func navigationFailed(
        in session: BrowserSession,
        error: any Error
    ) {
        guard let load = session.navigationPhase.load,
              transitionNavigation(.failed(error), on: session) else {
            Log.webView.info("Service.navigation ignored-stale-failure domain=\(domain) session=\(session.logLabel)")
            return
        }
        Log.webView.error("Service.navigation failed domain=\(domain) session=\(session.logLabel) nav=\(load.generation) error=\(LogPrivacy.text(error.localizedDescription))")
    }

    func receive(_ event: BrowserSession.NavigationEvent, from session: BrowserSession) async {
        guard owns(session) else { return }
        switch event {
        case .started:
            guard transitionNavigation(event, on: session) else { return }
            Log.webView.info("Service.navigation event=start domain=\(domain) session=\(session.logLabel) phase=\(session.navigationPhase.logLabel) active=\(activeInvocationCount(in: session)) queued=\(queuedInvocationCount(in: session))")

        case .redirected:
            guard let load = session.navigationPhase.load else {
                Log.webView.info("Service.navigation ignored-stale-redirect domain=\(domain) session=\(session.logLabel)")
                return
            }
            guard transitionNavigation(event, on: session) else { return }
            Log.webView.info("Service.navigation event=redirect domain=\(domain) session=\(session.logLabel) nav=\(load.generation) url=\(LogPrivacy.url(session.page.url?.absoluteString ?? "?"))")

        case .committed:
            guard case .navigating(let load) = session.navigationPhase else {
                Log.webView.info("Service.navigation ignored-stale-commit domain=\(domain) session=\(session.logLabel)")
                return
            }
            guard transitionNavigation(event, on: session) else { return }
            Log.webView.info("Service.navigation event=commit domain=\(domain) session=\(session.logLabel) nav=\(load.generation)")

        case .finished(let url):
            guard case .navigating(let load) = session.navigationPhase else {
                Log.webView.info("Service.navigation ignored-stale-finish domain=\(domain) session=\(session.logLabel) url=\(LogPrivacy.url(url.absoluteString))")
                return
            }
            guard transitionNavigation(event, on: session) else { return }
            let ms = session.navigationStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
            Log.webView.info("Service.navigation event=finish domain=\(domain) session=\(session.logLabel) nav=\(load.generation) committed=\(load.committed) ms=\(ms) url=\(LogPrivacy.url(url.absoluteString))")
            guard case .settling(let settlement) = session.navigationPhase else { return }
            scheduleNavigationSettlement(in: session, settlement: settlement)

        case .settled(let settlement):
            guard transitionNavigation(event, on: session) else { return }
            Log.webView.info("Service.navigation settled domain=\(domain) session=\(session.logLabel) nav=\(settlement.load.generation) delayMs=400 url=\(LogPrivacy.url(settlement.url.absoluteString))")
            await verifyNavigation(in: session, load: settlement.load, url: settlement.url)

        case .failed(let error):
            navigationFailed(in: session, error: error)

        case .becameDownload:
            guard let load = session.navigationPhase.load else { return }
            guard transitionNavigation(event, on: session) else { return }
            Log.webView.error("Service.navigation event=download domain=\(domain) session=\(session.logLabel) nav=\(load.generation)")

        case .webContentProcessTerminated:
            let active = activeInvocationCount(in: session)
            let queued = queuedInvocationCount(in: session)
            let phase = session.navigationPhase.logLabel
            guard transitionNavigation(event, on: session) else { return }
            let message = "Service.navigation event=process-terminated domain=\(domain) session=\(session.logLabel) phase=\(phase) active=\(active) queued=\(queued)"
            if active == 0, queued == 0 {
                Log.webView.info(message)
            } else {
                Log.webView.error(message)
            }

        default:
            _ = transitionNavigation(event, on: session)
        }
    }

}
