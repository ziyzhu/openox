import SwiftUI
import WebKit

struct ConversationInlineServicePages: View {
    let anchors: [UUID: Anchor<CGRect>]
    let browserPage: WebPage?
    let browserPageMount: WebPageMountCoordinator

    var body: some View {
        if let page = browserPage,
           let ownerID = browserPageMount.inlineOwnerID(for: page),
           let anchor = anchors[ownerID] {
            GeometryReader { geometry in
                let frame = geometry[anchor]
                MountedWebPageView(mount: WebPageMount(page: page, ownerID: ownerID, coordinator: browserPageMount))
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
