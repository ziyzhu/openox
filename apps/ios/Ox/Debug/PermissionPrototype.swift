#if DEBUG && targetEnvironment(simulator)
import SwiftUI

struct PermissionPrototypeScreen: View {
    let mode: String
    @Environment(ServiceManager.self) private var serviceManager

    private var example: PermissionPrototypeExample { PermissionPrototypeExample(mode: mode) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "line.3.horizontal")
                    .frame(width: 44, height: 44)
                Spacer()
                Text(example.chatTitle)
                    .font(.headline)
                Spacer()
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
            }
            .padding(.horizontal, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(example.userMessage)
                        .padding(16)
                        .background(Theme.Colors.bubble, in: RoundedRectangle(cornerRadius: 20))
                        .padding(.leading, 40)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    PermissionRequestCard(
                        request: PermissionRequest(
                            id: UUID(),
                            prompt: example.presentation.prompt,
                            options: example.options,
                            presentation: example.presentation
                        )!
                    ) { _ in }
                }
                .padding(16)
            }
        }
        .foregroundStyle(Theme.Colors.onSurface)
        .background(Theme.Colors.background)
        .task {
            _ = await serviceManager.refreshServices(locale: nil)
        }
    }
}

private struct PermissionPrototypeExample {
    let mode: String

    private var kind: Kind { Kind(rawValue: mode) ?? .service }

    var chatTitle: String {
        switch kind {
        case .service: "Proposal for Alex"
        case .disclosure: "Update project tracker"
        case .destructive: "Clean up old chats"
        case .attachment: "Research with ChatGPT"
        case .scheduled: "Daily briefing"
        }
    }

    var userMessage: String {
        switch kind {
        case .service: "Send Alex the updated proposal PDF for tomorrow’s review."
        case .disclosure: "Update the signed-in project tracker with today’s status."
        case .destructive: "Delete the archived launch-planning chat."
        case .attachment: "Use ChatGPT to research the latest launch guidance."
        case .scheduled: "Schedule the daily briefing for 8:00 AM."
        }
    }

    var presentation: PermissionPresentation {
        switch kind {
        case .service:
            PermissionPresentation(
                title: "Gmail - Send email",
                purpose: "Send Alex the updated proposal so they can review it before tomorrow’s meeting.",
                arguments: Self.emailArguments
            )
        case .disclosure:
            PermissionPresentation(
                title: "Browser - Execute script - docs.google.com",
                purpose: "Update the project tracker with today’s completed work.",
                disclosure: "Dangerous mode gives the agent full control of this website, including signed-in data and network access. Always allow applies to every page Web visits.",
                arguments: Self.browserArguments
            )
        case .destructive:
            PermissionPresentation(
                title: "Ox - Delete chat",
                purpose: "Remove the archived launch-planning chat from this device."
            )
        case .attachment:
            PermissionPresentation(
                title: "ChatGPT - Attach",
                disclosure: "Its actions and your signed-in data become available to this chat."
            )
        case .scheduled:
            PermissionPresentation(
                title: "Ox - Schedule",
                purpose: "Schedule /daily-briefing for every day at 8:00 AM. Future use of service capabilities will still follow their normal approval policy."
            )
        }
    }

    var options: [String] {
        switch kind {
        case .scheduled: ["Schedule", "Cancel"]
        case .service, .disclosure, .destructive, .attachment: ["Approve", "Always allow", "Deny"]
        }
    }

    private enum Kind: String {
        case service
        case disclosure
        case destructive
        case attachment
        case scheduled
    }

    private static let emailArguments = """
    {
      "attachments" : [
        "proposal.pdf"
      ],
      "body" : "Hi Alex, here’s the updated proposal for tomorrow’s review. Please let me know if you have any questions.",
      "subject" : "Updated proposal",
      "to" : "alex@example.com"
    }
    """

    private static let browserArguments = """
    {
      "script" : "document.querySelector('[data-project-status]').textContent = 'Ready for review'"
    }
    """
}

#endif
