import Foundation
import WebKit

extension Service.ServiceWebPage {
    enum NavigationVerification {
        case ready
        case offDomain
        case dispatcherMissing
    }

    enum NavigationEvent {
        case requested(NavigationLease)
        case reserved(NavigationLease)
        case loadStarted(NavigationLoad)
        case started
        case redirected
        case committed
        case finished(URL)
        case settled(NavigationSettlement)
        case verified(NavigationLoad, URL, NavigationVerification)
        case serviceDomainLost
        case startFailed(NavigationLease)
        case abandoned(NavigationLease, String)
        case timedOut(NavigationLease)
        case failed(any Error)
        case becameDownload
        case webContentProcessTerminated
        case superseded(NavigationLoad)
        case terminated(any Error)

        var logLabel: String {
            switch self {
            case .requested: "requested"
            case .reserved: "reserved"
            case .loadStarted: "loadStarted"
            case .started: "started"
            case .redirected: "redirected"
            case .committed: "committed"
            case .finished: "finished"
            case .settled: "settled"
            case .verified: "verified"
            case .serviceDomainLost: "serviceDomainLost"
            case .startFailed: "startFailed"
            case .abandoned: "abandoned"
            case .timedOut: "timedOut"
            case .failed: "failed"
            case .becameDownload: "becameDownload"
            case .webContentProcessTerminated: "webContentProcessTerminated"
            case .superseded: "superseded"
            case .terminated: "terminated"
            }
        }
    }

    @discardableResult
    func transition(
        _ event: NavigationEvent,
        canReserve: Bool,
        failPending: (any Error) -> Void,
        advance: () -> Void
    ) -> Bool {
        switch event {
        case .requested(let lease):
            switch navigationPhase {
            case .ready, .unavailable:
                navigationPhase = .pending(lease)
                return true
            case .pending, .reserved, .navigating, .settling, .verifying:
                return false
            }

        case .reserved(let lease):
            guard case .pending(let current) = navigationPhase,
                  current === lease,
                  canReserve else { return false }
            navigationPhase = .reserved(lease)
            lease.settleReservation(true)
            return true

        case .loadStarted(let load):
            guard case .reserved(let lease) = navigationPhase,
                  load.lease === lease else { return false }
            navigationPhase = .navigating(load)
            navigationStartedAt = .now
            return true

        case .started:
            if let current = navigationPhase.load, current.started { return false }
            interruptEvaluations(with: Service.EvalError.contextInvalidated)
            navigationGeneration += 1
            navigationStartedAt = .now
            let load: NavigationLoad
            switch navigationPhase {
            case .navigating(let current), .verifying(let current, _):
                current.expectedURL = page.url ?? current.expectedURL
                load = current
            case .settling(let settlement):
                settlement.cancel()
                settlement.load.expectedURL = page.url ?? settlement.load.expectedURL
                load = settlement.load
            case .pending(let lease):
                lease.settleReservation(false)
                load = NavigationLoad(lease: nil, generation: navigationGeneration, expectedURL: page.url)
            case .reserved(let lease):
                lease.timeoutTask?.cancel()
                lease.settleCompletion(nil)
                load = NavigationLoad(lease: nil, generation: navigationGeneration, expectedURL: page.url)
            case .ready, .unavailable:
                load = NavigationLoad(lease: nil, generation: navigationGeneration, expectedURL: page.url)
            }
            load.generation = navigationGeneration
            load.started = true
            navigationPhase = .navigating(load)
            return true

        case .redirected:
            guard let load = navigationPhase.load else { return false }
            load.expectedURL = page.url ?? load.expectedURL
            return true

        case .committed:
            guard case .navigating(let load) = navigationPhase else { return false }
            load.committed = true
            return true

        case .finished(let url):
            guard case .navigating(let load) = navigationPhase else { return false }
            finishedNavigationGeneration = load.generation
            navigationPhase = .settling(NavigationSettlement(load: load, url: url))
            return true

        case .settled(let settlement):
            guard navigationGeneration == settlement.load.generation,
                  case .settling(let current) = navigationPhase,
                  current === settlement else { return false }
            settlement.task = nil
            navigationPhase = .verifying(settlement.load, settlement.url)
            return true

        case .verified(let load, let url, let verification):
            guard navigationGeneration == load.generation,
                  case .verifying(let currentLoad, let currentURL) = navigationPhase,
                  currentLoad === load,
                  currentURL == url else { return false }
            load.lease?.timeoutTask?.cancel()
            switch verification {
            case .ready:
                navigationPhase = .ready
                load.lease?.settleCompletion(url)
            case .offDomain:
                navigationPhase = .unavailable("off-domain")
                load.lease?.settleCompletion(url)
            case .dispatcherMissing:
                navigationPhase = .unavailable("dispatcher")
                load.lease?.settleCompletion(nil)
                failPending(Service.EvalError.notReady)
            }
            advance()
            return true

        case .serviceDomainLost:
            guard isReady else { return false }
            navigationPhase = .unavailable("off-domain")
            return true

        case .startFailed(let lease):
            guard case .navigating(let load) = navigationPhase,
                  load.lease === lease else { return false }
            navigationPhase = .unavailable("start-failed")
            lease.settleCompletion(nil)
            failPending(Service.EvalError.notActive)
            return true

        case .abandoned(let lease, let reason):
            switch navigationPhase {
            case .pending(let current) where current.originates(from: lease):
                navigationPhase = .unavailable(reason)
                current.settleReservation(false)
            case .reserved(let current) where current.originates(from: lease):
                navigationPhase = .unavailable(reason)
                current.settleCompletion(nil)
            case .navigating(let load), .verifying(let load, _):
                guard let current = load.lease,
                      current.originates(from: lease) else { return false }
                page.stopLoading()
                navigationPhase = .unavailable(reason)
                current.timeoutTask?.cancel()
                current.settleCompletion(nil)
            case .settling(let settlement):
                guard let current = settlement.load.lease,
                      current.originates(from: lease) else { return false }
                settlement.cancel()
                page.stopLoading()
                navigationPhase = .unavailable(reason)
                current.timeoutTask?.cancel()
                current.settleCompletion(nil)
            default:
                return false
            }
            failPending(CancellationError())
            return true

        case .timedOut(let lease):
            guard navigationPhase.load?.lease === lease else { return false }
            navigationPhase.settlement?.cancel()
            page.stopLoading()
            navigationPhase = .unavailable("timeout")
            lease.timeoutTask?.cancel()
            lease.settleCompletion(nil)
            failPending(Service.EvalError.navigationTimeout(lease.timeout))
            return true

        case .failed(let error):
            guard let load = navigationPhase.load else { return false }
            navigationPhase.settlement?.cancel()
            load.lease?.timeoutTask?.cancel()
            navigationFailure = navigationFailure ?? error.localizedDescription
            navigationPhase = .unavailable("failed")
            load.lease?.settleCompletion(nil)
            failPending(Service.EvalError.navigationFailed(error.localizedDescription))
            advance()
            return true

        case .becameDownload:
            guard let load = navigationPhase.load else { return false }
            navigationPhase.settlement?.cancel()
            load.lease?.timeoutTask?.cancel()
            load.lease?.settleCompletion(nil)
            navigationPhase = .unavailable("download")
            failPending(Service.EvalError.navigationFailed("navigation became a download"))
            return true

        case .webContentProcessTerminated:
            settleActiveNavigation()
            page.stopLoading()
            navigationPhase = .unavailable("process-terminated")
            interruptEvaluations(with: Service.EvalError.contextInvalidated)
            failPending(Service.EvalError.navigationFailed("web content process terminated"))
            return true

        case .superseded(let load):
            guard navigationPhase.load === load else { return false }
            navigationPhase.settlement?.cancel()
            load.lease?.timeoutTask?.cancel()
            navigationPhase = .unavailable("superseded")
            return true

        case .terminated(let error):
            settleActiveNavigation()
            navigationPhase = .unavailable("terminated")
            failPending(error)
            interruptEvaluations(with: error)
            return true
        }
    }

    func activeLease(originatingFrom lease: NavigationLease) -> NavigationLease? {
        let active: NavigationLease? = switch navigationPhase {
        case .pending(let current), .reserved(let current): current
        case .navigating(let load), .verifying(let load, _): load.lease
        case .settling(let settlement): settlement.load.lease
        case .ready, .unavailable: nil
        }
        guard let active, active.originates(from: lease) else { return nil }
        return active
    }

    private func settleActiveNavigation() {
        switch navigationPhase {
        case .pending(let lease):
            lease.settleReservation(false)
        case .reserved(let lease):
            lease.settleCompletion(nil)
        case .navigating(let load), .verifying(let load, _):
            load.lease?.timeoutTask?.cancel()
            load.lease?.settleCompletion(nil)
        case .settling(let settlement):
            settlement.cancel()
            settlement.load.lease?.timeoutTask?.cancel()
            settlement.load.lease?.settleCompletion(nil)
        case .ready, .unavailable:
            break
        }
    }
}

extension Service {
    @discardableResult
    func transitionNavigation(
        _ event: ServiceWebPage.NavigationEvent,
        on page: ServiceWebPage
    ) -> Bool {
        let isOwned = owns(page)
        if !isOwned, case .terminated = event {
            return page.transition(
                event,
                canReserve: false,
                failPending: { _ in },
                advance: {}
            )
        }
        guard isOwned else {
            Log.service.error("Service.navigation transition rejected domain=\(domain) session=\(page.logLabel) event=\(event.logLabel) ownership=lost")
            return false
        }
        let accepted = page.transition(
            event,
            canReserve: activeInvocationCount(in: page) == 0,
            failPending: { [weak self, weak page] error in
                guard let self, let page, self.owns(page) else { return }
                self.manager.actionScheduler.failPending(on: page, error: error)
            },
            advance: { [weak self, weak page] in
                guard let self, let page, self.owns(page) else { return }
                self.advancePage(page)
            }
        )
        if !accepted {
            Log.service.error("Service.navigation transition rejected domain=\(domain) session=\(page.logLabel) event=\(event.logLabel) phase=\(page.navigationPhase.logLabel)")
        }
        return accepted
    }

    func activeInvocationCount(in page: ServiceWebPage) -> Int {
        manager.actionScheduler.activeInvocationCount(on: page)
    }

    func queuedInvocationCount(in page: ServiceWebPage) -> Int {
        manager.actionScheduler.queuedInvocationCount(on: page)
    }
}
