import SwiftUI
import WebKit

struct ConversationInlineServicePages: View {
    let anchors: [UUID: Anchor<CGRect>]
    let browserPage: WebPage?
    let browserPageMount: WebPageMountCoordinator
    let servicePageLinks: [UUID: ServiceInspectorLink]
    let servicePageOwnerIDs: [UUID]
    @Environment(ServiceManager.self) private var serviceManager

    private var servicePages: [UUID: WebPage] {
        var pages: [UUID: WebPage] = [:]
        for link in servicePageLinks.values {
            guard let pageID = link.pageID,
                  let service = serviceManager.inspectionService(domain: link.domain),
                  let page = service.servicePage(id: pageID) else { continue }
            pages[pageID] = page.page
        }
        return pages
    }

    var body: some View {
        Group {
            browserContent
            ForEach(servicePages.keys.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { pageID in
                if let page = servicePages[pageID] {
                    inlinePage(page, mount: browserPageMount.coordinator(for: pageID))
                }
            }
        }
        .onChange(of: servicePageOwnerIDs, initial: true) { _, _ in reconcileServicePages() }
        .onChange(of: servicePages.mapValues(ObjectIdentifier.init), initial: true) { _, _ in reconcileServicePages() }
    }

    private func reconcileServicePages() {
        for pageID in Set(servicePageLinks.values.compactMap(\.pageID)) {
            let ownerIDs = servicePageOwnerIDs.filter { servicePageLinks[$0]?.pageID == pageID }
            browserPageMount.coordinator(for: pageID).reconcile(page: servicePages[pageID], ownerIDs: ownerIDs)
        }
    }

    @ViewBuilder
    private var browserContent: some View {
        if let page = browserPage {
            inlinePage(page, mount: browserPageMount)
        }
    }

    @ViewBuilder
    private func inlinePage(_ page: WebPage, mount: WebPageMountCoordinator) -> some View {
        if let ownerID = mount.inlineOwnerID(for: page),
           let anchor = anchors[ownerID] {
            GeometryReader { geometry in
                let frame = geometry[anchor]
                MountedWebPageView(mount: WebPageMount(page: page, ownerID: ownerID, coordinator: mount))
                    .frame(width: frame.width, height: frame.height)
                    .clipShape(
                        UnevenRoundedRectangle(
                            bottomLeadingRadius: Theme.Radius.lg,
                            bottomTrailingRadius: Theme.Radius.lg,
                            style: .continuous
                        )
                    )
                    .position(x: frame.midX, y: frame.midY)
            }
            .clipped()
        }
    }
}

struct ConversationServiceControlBlock: View {
    let control: ServiceControl
    let interactionID: UUID?
    let conversation: Conversation
    let prepareServiceControl: (ServiceControl) -> Bool

    var body: some View {
        ServiceControlView(
            control: control,
            isActive: interactionID != nil,
            reflectsAuthentication: false,
            login: { domain in
                guard prepareServiceControl(control) else { return false }
                return await conversation.loginService(domain: domain, resumeAgent: false) != nil
            },
            onResolved: { result in
                guard let interactionID else { return }
                conversation.resolveServiceControl(id: interactionID, result: result)
            }
        )
    }
}
