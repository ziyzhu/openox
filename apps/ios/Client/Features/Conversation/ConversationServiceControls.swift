import SwiftUI
import WebKit
import Observation

@MainActor
@Observable
final class ConversationBotControlPresenter: ServiceHandoffPresenting {
    private(set) var session: ServiceHandoffSession?
    let pageMount = WebPageMountCoordinator()

    func present(session: ServiceHandoffSession) async -> ServiceHandoffSession.Outcome {
        guard self.session == nil else {
            Log.ui.warning("ConversationBotControlPresenter rejected domain=\(session.serviceDomain) reason=occupied")
            session.presentationFailed()
            return .failed
        }
        self.session = session
        pageMount.reconcile(page: session.page, ownerIDs: [session.id])
        Log.ui.info("ConversationBotControlPresenter present domain=\(session.serviceDomain)")
        let outcome = await session.run()
        if self.session === session {
            pageMount.clear()
            self.session = nil
        }
        Log.ui.info("ConversationBotControlPresenter finish domain=\(session.serviceDomain) outcome=\(outcome.rawValue)")
        return outcome
    }
}

@MainActor
@Observable
final class ConversationServiceAuthPresenter: ServiceAuthPresenting {
    private(set) var session: ServiceAuthSession?
    let pageMount = WebPageMountCoordinator()

    func present(session: ServiceAuthSession) async -> ServiceAuthSession.Outcome {
        if let outcome = await session.preflight(for: .seconds(1)) {
            Log.ui.info("ConversationServiceAuthPresenter preflight domain=\(session.serviceDomain) outcome=\(outcome.rawValue)")
            return outcome
        }
        guard self.session == nil else {
            Log.ui.warning("ConversationServiceAuthPresenter rejected domain=\(session.serviceDomain) reason=occupied")
            session.presentationFailed()
            return .failed
        }
        self.session = session
        pageMount.reconcile(page: session.page, ownerIDs: [session.id])
        Log.ui.info("ConversationServiceAuthPresenter present domain=\(session.serviceDomain)")
        let outcome = await session.run()
        if self.session === session {
            pageMount.clear()
            self.session = nil
        }
        Log.ui.info("ConversationServiceAuthPresenter finish domain=\(session.serviceDomain) outcome=\(outcome.rawValue)")
        return outcome
    }
}

private struct InlineServicePageHost: View {
    let anchor: Anchor<CGRect>
    let mount: WebPageMount

    var body: some View {
        GeometryReader { geometry in
            let frame = geometry[anchor]
            MountedWebPageView(mount: mount)
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

struct ConversationInlineServicePages: View {
    let anchors: [UUID: Anchor<CGRect>]
    let browserPage: WebPage?
    let browserPageMount: WebPageMountCoordinator
    let serviceAuthPresenter: ConversationServiceAuthPresenter
    let botControlPresenter: ConversationBotControlPresenter

    var body: some View {
        if let page = browserPage,
           let ownerID = browserPageMount.inlineOwnerID(for: page),
           let anchor = anchors[ownerID] {
            InlineServicePageHost(
                anchor: anchor,
                mount: WebPageMount(page: page, ownerID: ownerID, coordinator: browserPageMount)
            )
        }
        if let session = serviceAuthPresenter.session,
           let ownerID = serviceAuthPresenter.pageMount.inlineOwnerID(for: session.page),
           let anchor = anchors[ownerID] {
            InlineServicePageHost(
                anchor: anchor,
                mount: WebPageMount(page: session.page, ownerID: ownerID, coordinator: serviceAuthPresenter.pageMount)
            )
        }
        if let session = botControlPresenter.session,
           let ownerID = botControlPresenter.pageMount.inlineOwnerID(for: session.page),
           let anchor = anchors[ownerID] {
            InlineServicePageHost(
                anchor: anchor,
                mount: WebPageMount(page: session.page, ownerID: ownerID, coordinator: botControlPresenter.pageMount)
            )
        }
    }
}

struct ConversationServiceControlBlock: View {
    let control: ServiceControl
    let interactionID: UUID?
    let conversation: Conversation
    let botControlPresenter: ConversationBotControlPresenter
    let serviceAuthPresenter: ConversationServiceAuthPresenter
    let isBotControlPresentedInSheet: Bool
    let isServiceAuthPresentedInSheet: Bool
    let expandBotControl: (ServiceHandoffSession) -> Void
    let expandServiceAuth: (ServiceAuthSession) -> Void
    let prepareServiceControl: (ServiceControl) -> Bool

    var body: some View {
        if case .botControl = control, interactionID != nil {
            InlineBotControlView(
                control: control,
                session: botControlPresenter.session,
                pageMount: botControlPresenter.pageMount,
                isPresentedInSheet: isBotControlPresentedInSheet,
                expand: expandBotControl,
                cancel: { $0.cancel() }
            )
        } else if case .signIn = control, interactionID != nil {
            InlineServiceAuthView(
                control: control,
                session: serviceAuthPresenter.session,
                pageMount: serviceAuthPresenter.pageMount,
                isPresentedInSheet: isServiceAuthPresentedInSheet,
                expand: expandServiceAuth,
                cancel: {
                    if let session = serviceAuthPresenter.session {
                        session.cancel()
                    } else if let interactionID {
                        conversation.resolveServiceControl(id: interactionID, result: nil)
                    }
                }
            )
        } else {
            ServiceControlView(
                control: control,
                isActive: interactionID != nil,
                reflectsAuthentication: false,
                signIn: { domain in
                    guard prepareServiceControl(control) else { return false }
                    return await conversation.signInService(domain: domain, resumeAgent: false) != nil
                },
                completeBotControl: { domain, args in
                    guard prepareServiceControl(control) else { return false }
                    return await conversation.completeBotControl(domain: domain, args: args, resumeAgent: false)
                },
                completePayment: { domain, args in
                    guard prepareServiceControl(control) else { return nil }
                    return await conversation.completePayment(domain: domain, args: args)
                },
                onResolved: { result in
                    guard let interactionID else { return }
                    conversation.resolveServiceControl(id: interactionID, result: result)
                }
            )
        }
    }
}
