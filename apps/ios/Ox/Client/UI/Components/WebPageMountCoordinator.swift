import Observation
import SwiftUI
import WebKit

@MainActor
@Observable
final class WebPageMountCoordinator {
    enum Placement: Equatable {
        case idle
        case inline(UUID)
        case detached(UUID)
    }

    private(set) var placement: Placement = .idle
    @ObservationIgnored private var pageID: ObjectIdentifier?
    @ObservationIgnored private var preferredOwnerID: UUID?
    @ObservationIgnored private var mountedPageID: ObjectIdentifier?
    @ObservationIgnored private var mountedOwnerID: UUID?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var unmountWaiters: [CheckedContinuation<Void, Never>] = []

    func isInline(page: WebPage?, ownerID: UUID) -> Bool {
        guard placement == .inline(ownerID), let page else { return false }
        return pageID == ObjectIdentifier(page)
    }

    func inlineOwnerID(for page: WebPage?) -> UUID? {
        guard case .inline(let ownerID) = placement,
              let page, pageID == ObjectIdentifier(page) else { return nil }
        return ownerID
    }

    func reconcile(page: WebPage?, ownerIDs: [UUID]) {
        let nextPageID = page.map(ObjectIdentifier.init)
        let pageChanged = pageID != nextPageID
        if pageChanged {
            pageID = nextPageID
            preferredOwnerID = nil
            revision += 1
            placement = .idle
        }
        let preferred = ownerIDs.last
        let previousPreferred = preferredOwnerID
        preferredOwnerID = preferred
        guard let page, let preferred else {
            clear()
            return
        }
        if !pageChanged, case .detached(let ownerID) = placement, ownerIDs.contains(ownerID) { return }
        if !pageChanged, case .inline(let ownerID) = placement,
           ownerIDs.contains(ownerID), preferred == previousPreferred { return }
        activate(page: page, ownerID: preferred)
    }

    func activate(page: WebPage, ownerID: UUID) {
        let nextPageID = ObjectIdentifier(page)
        guard pageID != nextPageID || placement != .inline(ownerID) else { return }
        pageID = nextPageID
        revision += 1
        let request = revision
        placement = .idle
        Log.webView.info("WebPageMount.activate owner=\(ownerID)")
        Task { @MainActor in
            await waitUntilUnmounted()
            guard revision == request else { return }
            placement = .inline(ownerID)
            Log.webView.info("WebPageMount.inline owner=\(ownerID)")
        }
    }

    func detach(page: WebPage, ownerID: UUID) async -> Bool {
        guard pageID == ObjectIdentifier(page) else { return false }
        if placement == .detached(ownerID) { return true }
        revision += 1
        let request = revision
        placement = .detached(ownerID)
        Log.webView.info("WebPageMount.detaching owner=\(ownerID)")
        await waitUntilUnmounted()
        return revision == request && placement == .detached(ownerID)
    }

    func restore(page: WebPage, ownerID: UUID) {
        guard pageID == ObjectIdentifier(page), placement == .detached(ownerID) else { return }
        activate(page: page, ownerID: ownerID)
    }

    func clear() {
        revision += 1
        pageID = nil
        preferredOwnerID = nil
        placement = .idle
    }

    func didMount(page: WebPage, ownerID: UUID) {
        guard isInline(page: page, ownerID: ownerID) else { return }
        mountedPageID = ObjectIdentifier(page)
        mountedOwnerID = ownerID
        Log.webView.info("WebPageMount.mounted owner=\(ownerID)")
    }

    func didUnmount(page: WebPage, ownerID: UUID) {
        guard mountedPageID == ObjectIdentifier(page), mountedOwnerID == ownerID else { return }
        mountedPageID = nil
        mountedOwnerID = nil
        let waiters = unmountWaiters
        unmountWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        Log.webView.info("WebPageMount.unmounted owner=\(ownerID)")
    }

    private func waitUntilUnmounted() async {
        await Task.yield()
        guard mountedPageID != nil else { return }
        await withCheckedContinuation { continuation in
            unmountWaiters.append(continuation)
        }
    }
}

struct WebPageMount {
    let page: WebPage
    let ownerID: UUID
    let coordinator: WebPageMountCoordinator
}

struct MountedWebPageView: View {
    let mount: WebPageMount

    var body: some View {
        WebContentView(page: mount.page)
            .onAppear {
                mount.coordinator.didMount(page: mount.page, ownerID: mount.ownerID)
            }
            .onDisappear {
                mount.coordinator.didUnmount(page: mount.page, ownerID: mount.ownerID)
            }
    }
}
