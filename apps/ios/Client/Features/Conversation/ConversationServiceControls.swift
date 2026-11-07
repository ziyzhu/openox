import SwiftUI
import WebKit

struct ConversationInlineServicePages: View {
    let anchors: [UUID: Anchor<CGRect>]
    let browserPage: WebPage?
    let browserPageMount: WebPageMountCoordinator
    let servicePageLinks: [UUID: ServiceInspectorLink]
    let servicePageOwnerIDs: [UUID]
    @Environment(ServiceManager.self) private var serviceManager

    private var latestPageOwnerID: UUID? {
        servicePageOwnerIDs.last { servicePageLinks[$0] != nil }
    }

    private var latestPage: WebPage? {
        guard let ownerID = latestPageOwnerID, let link = servicePageLinks[ownerID] else { return nil }
        guard let pageID = link.pageID else { return browserPage }
        return serviceManager.inspectionService(domain: link.domain)?.servicePage(id: pageID)?.page
    }

    var body: some View {
        GeometryReader { _ in
            if let page = latestPage {
                inlinePage(page, mount: browserPageMount)
            }
        }
        .onChange(of: latestPageOwnerID, initial: true) { _, _ in reconcilePage() }
        .onChange(of: latestPage.map(ObjectIdentifier.init), initial: true) { _, _ in reconcilePage() }
    }

    private func reconcilePage() {
        browserPageMount.reconcile(page: latestPage, ownerIDs: latestPageOwnerID.map { [$0] } ?? [])
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
