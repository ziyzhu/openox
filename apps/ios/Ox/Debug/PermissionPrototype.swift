#if DEBUG && targetEnvironment(simulator)
import SwiftUI

struct PermissionPrototypeScreen: View {
    let mode: String
    @Environment(ServiceManager.self) private var serviceManager

    private let arguments = """
    {
      "to": "alex@example.com",
      "subject": "Updated proposal",
      "body": "Hi Alex, here’s the updated proposal for tomorrow’s review. Please let me know if you have any questions.",
      "attachments": [
        "proposal.pdf"
      ]
    }
    """

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "line.3.horizontal")
                    .frame(width: 44, height: 44)
                Spacer()
                Text("Proposal for Alex")
                    .font(.headline)
                Spacer()
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
            }
            .padding(.horizontal, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Send Alex the updated proposal PDF for tomorrow’s review.")
                        .padding(16)
                        .background(Theme.Colors.bubble, in: RoundedRectangle(cornerRadius: 20))
                        .padding(.leading, 40)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    PermissionRequestCard(
                        request: PermissionRequest(
                            id: UUID(),
                            prompt: mode == "before"
                                ? "Gmail - Send email\nattachments: proposal.pdf\nbody: Hi Alex, here’s the updated proposal for tomorrow’s review. Please let me know if you have any questions.\nsubject: Updated proposal\nto: alex@example.com"
                                : "Gmail - Send email\nSend Alex the updated proposal so they can review it before tomorrow’s meeting.",
                            options: ["Approve", "Always allow", "Deny"]
                        )!,
                        arguments: mode == "before" ? nil : arguments
                    ) { _ in }
                }
                .padding(16)
            }
            Label("Waiting for your permission", systemImage: "hand.raised")
                .font(.subheadline)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .padding(20)
            Text("Permission design prototype · Sample data")
                .font(.caption2)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .padding(.bottom, 8)
        }
        .foregroundStyle(Theme.Colors.onSurface)
        .background(Theme.Colors.background)
        .task {
            _ = await serviceManager.refreshServices(locale: nil)
        }
    }
}

#endif
