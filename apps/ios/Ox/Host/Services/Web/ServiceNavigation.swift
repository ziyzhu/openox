import Foundation
import WebKit

extension Service {
    func observeNavigations(in session: ServiceWebPage) -> Task<Void, Never> {
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
                    if case WebPage.NavigationError.webContentProcessTerminated = error {
                        await self.receive(.webContentProcessTerminated, from: session)
                    } else {
                        await self.receive(.failed(error), from: session)
                    }
                }
            }
        }
    }

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
        operation: @escaping @MainActor @Sendable (ServiceWebPage) async throws -> T
    ) async throws -> T {
        guard domain != "ios:browser" else { throw EvalError.notActive }
        return try await manager.actionScheduler.schedule(
            action,
            kind: .navigation,
            operation: operation
        )
    }

    func navigate(_ url: URL, in page: ServiceWebPage, timeout: TimeInterval = 15) async -> URL? {
        await performNavigation(.load(URLRequest(url: url)), in: page, label: "load", timeout: timeout)
    }

    func reload(_ page: ServiceWebPage, fromOrigin: Bool = false, timeout: TimeInterval = 15) async -> URL? {
        await performNavigation(.reload(fromOrigin: fromOrigin), in: page, label: "reload", timeout: timeout)
    }

    func goBack(_ page: ServiceWebPage, timeout: TimeInterval = 15) async -> URL? {
        await performNavigation(.back, in: page, label: "back", timeout: timeout)
    }

    func goForward(_ page: ServiceWebPage, timeout: TimeInterval = 15) async -> URL? {
        await performNavigation(.forward, in: page, label: "forward", timeout: timeout)
    }

    func performNavigation(
        _ command: NavigationCommand,
        in session: ServiceWebPage,
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
        in session: ServiceWebPage,
        label: String,
        timeout: TimeInterval,
        predecessor: ServiceWebPage.NavigationLease? = nil
    ) -> ServiceWebPage.NavigationLease? {
        guard owns(session) else { return nil }
        let lease = ServiceWebPage.NavigationLease(label: label, timeout: timeout, predecessor: predecessor)
        if transitionNavigation(.requested(lease), on: session) {
            Log.webView.info("Service.navigation requested domain=\(domain) session=\(session.logLabel) id=\(lease.id.uuidString.prefix(8)) label=\(label) active=\(activeInvocationCount(in: session)) queued=\(queuedInvocationCount(in: session))")
            advancePage(session)
            return lease
        } else {
            Log.webView.info("Service.navigation rejected-busy domain=\(domain) session=\(session.logLabel) label=\(label) phase=\(session.navigationPhase.logLabel)")
            return nil
        }
    }

    func awaitNavigationReservation(
        _ lease: ServiceWebPage.NavigationLease,
        in session: ServiceWebPage
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
        lease: ServiceWebPage.NavigationLease,
        in session: ServiceWebPage
    ) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            guard owns(session),
                  case .reserved(let current) = session.navigationPhase,
                  current === lease else {
                continuation.resume(returning: nil)
                return
            }
            lease.completion = continuation
            let expectedURL: URL? = switch command {
            case .load(let request): request.url
            case .reload: session.page.url
            case .back: session.page.backForwardList.backList.last?.url
            case .forward: session.page.backForwardList.forwardList.first?.url
            }
            let load = ServiceWebPage.NavigationLoad(
                lease: lease,
                generation: session.navigationGeneration,
                expectedURL: expectedURL
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
                self.navigationTimedOut(lease, in: session)
            }
        }
    }

    func abandonNavigation(
        _ lease: ServiceWebPage.NavigationLease,
        in session: ServiceWebPage,
        reason: String
    ) {
        guard owns(session) else { return }
        let activeLease = session.activeLease(originatingFrom: lease)
        guard transitionNavigation(.abandoned(lease, reason), on: session),
              let activeLease else { return }
        Log.webView.info("Service.navigation abandoned domain=\(domain) session=\(session.logLabel) id=\(activeLease.id.uuidString.prefix(8)) origin=\(lease.id.uuidString.prefix(8)) label=\(activeLease.label) reason=\(reason)")
    }

    func abandonActiveNavigation(in session: ServiceWebPage, reason: String) {
        let lease: ServiceWebPage.NavigationLease? = switch session.navigationPhase {
        case .pending(let current), .reserved(let current): current
        case .navigating(let load), .verifying(let load, _): load.lease
        case .settling(let settlement): settlement.load.lease
        case .ready, .unavailable: nil
        }
        guard let lease else { return }
        abandonNavigation(lease, in: session, reason: reason)
    }

    func navigationTimedOut(
        _ lease: ServiceWebPage.NavigationLease,
        in session: ServiceWebPage
    ) {
        guard owns(session),
              session.navigationPhase.load?.lease === lease else { return }
        transitionNavigation(.timedOut(lease), on: session)
        Log.webView.error("Service.navigation timeout domain=\(domain) session=\(session.logLabel) id=\(lease.id.uuidString.prefix(8)) label=\(lease.label) seconds=\(Int(lease.timeout))")
    }

    func verifyNavigation(
        in session: ServiceWebPage,
        load: ServiceWebPage.NavigationLoad,
        url: URL
    ) async {
        let generation = load.generation
        let host = url.host?.lowercased()
        let serviceHost = host.map(isServiceHost) == true
        let dispatcherReady: Bool
        if domain == "ios:browser" {
            dispatcherReady = true
        } else if serviceHost {
            dispatcherReady = await dispatcherIsReady(in: session, generation: generation)
        } else {
            dispatcherReady = false
        }
        if dispatcherReady {
            guard transitionNavigation(.verified(load, url, .ready), on: session) else { return }
            Log.webView.info("Service.navigation ready domain=\(domain) session=\(session.logLabel) nav=\(generation) active=\(activeInvocationCount(in: session)) queued=\(queuedInvocationCount(in: session))")
        } else if ServiceHandoffSession.allowsNavigation(to: url), !serviceHost {
            guard transitionNavigation(.verified(load, url, .offDomain), on: session) else { return }
            Log.webView.info("Service.navigation off-domain domain=\(domain) session=\(session.logLabel) nav=\(generation) host=\(host ?? "?") queued=\(queuedInvocationCount(in: session))")
        } else {
            guard transitionNavigation(.verified(load, url, .dispatcherMissing), on: session) else { return }
            Log.webView.error("Service.navigation dispatcher-missing domain=\(domain) session=\(session.logLabel) nav=\(generation) host=\(host ?? "?")")
        }
    }

    func scheduleNavigationSettlement(
        in session: ServiceWebPage,
        settlement: ServiceWebPage.NavigationSettlement
    ) {
        settlement.task = Task { @MainActor [weak self, weak session, weak settlement] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, let session, let settlement else { return }
            await self.receive(.settled(settlement), from: session)
        }
    }

    func navigationFailed(
        in session: ServiceWebPage,
        error: any Error
    ) {
        guard let load = session.navigationPhase.load,
              transitionNavigation(.failed(error), on: session) else {
            Log.webView.info("Service.navigation ignored-stale-failure domain=\(domain) session=\(session.logLabel)")
            return
        }
        Log.webView.error("Service.navigation failed domain=\(domain) session=\(session.logLabel) nav=\(load.generation) error=\(LogPrivacy.text(error.localizedDescription))")
    }

    func receive(_ event: ServiceWebPage.NavigationEvent, from session: ServiceWebPage) async {
        guard owns(session) else { return }
        switch event {
        case .started:
            if let current = session.navigationPhase.load, current.started {
                Log.webView.info("Service.navigation ignored-duplicate-start domain=\(domain) session=\(session.logLabel) nav=\(current.generation)")
                return
            }
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
            guard transitionNavigation(event, on: session) else { return }
            Log.webView.error("Service.navigation event=process-terminated domain=\(domain) session=\(session.logLabel) active=\(activeInvocationCount(in: session)) queued=\(queuedInvocationCount(in: session))")

        default:
            _ = transitionNavigation(event, on: session)
        }
    }

    func coordinatePageNavigation(
        _ request: URLRequest,
        in session: ServiceWebPage,
        superseding load: ServiceWebPage.NavigationLoad? = nil
    ) -> Bool {
        if let load {
            guard transitionNavigation(.superseded(load), on: session) else { return false }
            Log.webView.warning("Service.navigation replaced domain=\(domain) session=\(session.logLabel) old=\(load.generation) intent=page")
        }
        let timeout: TimeInterval = auth.isSigningIn ? 300 : 15
        guard let lease = requestNavigation(
            in: session,
            label: "page",
            timeout: timeout,
            predecessor: load?.lease
        ) else {
            load?.lease?.settleCompletion(nil)
            return false
        }
        session.interruptEvaluations(with: EvalError.contextInvalidated)
        Task { @MainActor [weak self, weak session, weak lease] in
            guard let self, let session, let lease,
                  await self.awaitNavigationReservation(lease, in: session) else { return }
            _ = await self.startNavigation(.load(request), lease: lease, in: session)
        }
        return true
    }

    func isSameDocumentNavigation(from current: URL?, to requested: URL?) -> Bool {
        guard let current, let requested, current != requested,
              var currentParts = URLComponents(url: current, resolvingAgainstBaseURL: false),
              var requestedParts = URLComponents(url: requested, resolvingAgainstBaseURL: false) else { return false }
        currentParts.fragment = nil
        requestedParts.fragment = nil
        return currentParts == requestedParts
    }

    func dispatcherIsReady(in session: ServiceWebPage, generation: Int) async -> Bool {
        guard owns(session), session.navigationGeneration == generation else { return false }
        do {
            let raw = try await evalOnce(
                session,
                "return typeof window.ox?.callServiceAction === 'function';",
                timeout: 5
            )
            return raw as? Bool == true
        } catch {
            Log.webView.error("Service.dispatcher probe failed domain=\(domain) session=\(session.logLabel) nav=\(generation) error=\(LogPrivacy.text(error.localizedDescription))")
            return false
        }
    }

    // MARK: - Actions

}
