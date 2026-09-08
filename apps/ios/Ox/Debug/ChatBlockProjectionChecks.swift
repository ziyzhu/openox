#if targetEnvironment(simulator)
import Foundation

enum ChatBlockProjectionChecks {
    @MainActor
    static func failures() -> [String] {
        var failures: [String] = []
        let turnID = TurnID()
        let controls: [ServiceControl] = [
            .signIn(domain: "example.com", serviceName: "Example"),
            .botControl(domain: "example.com", serviceName: "Example", args: .object([:])),
            .payment(domain: "example.com", serviceName: "Example", args: .object([:])),
        ]
        for control in controls {
            let content = Block(.agentContent([
                .text(" \n"), .progress(""), .serviceControl(control),
                .serviceControl(control), .text("Response"),
            ]))
            let pending = Chat.PendingServiceControl(
                id: UUID(), control: control,
                source: .init(blockID: content.id, itemIndex: 2)
            )
            let active = ChatBlock.project(
                [(content, turnID)], thinkingActivity: nil, isBusy: true,
                interaction: .serviceControl(pending)
            )
            let settled = ChatBlock.project(
                [(content, turnID)], thinkingActivity: nil, isBusy: false, interaction: nil
            )
            if active.count != 4 || settled.count != 4 {
                failures.append("Empty content must not add rows; service history must remain visible")
            }
            if active.map(\.id) != settled.map(\.id) {
                failures.append("Resolving service controls must preserve block identity")
            }
            if active.filter(\.isActiveInteraction).map(\.id) != Array(active.prefix(1)).map(\.id)
                || settled.contains(where: \.isActiveInteraction) {
                failures.append("Repeated service controls must activate only their exact source")
            }
            if active.dropLast().contains(where: { $0.spacingBefore != ChatTranscriptMetrics.blockSpacing }) {
                failures.append("Cards and responses must share block spacing")
            }
            if case .responseFooter(_, .streaming) = active.last?.kind {} else {
                failures.append("An active response must reserve its streaming footer")
            }
        }
        let trace = ThinkingTrace(entries: [], completedAt: Date())
        let sources: [(block: Block, turnID: TurnID)] = [
            (Block(.thinking(trace)), turnID),
            (Block(.thinking(trace)), turnID),
            (Block(.agentContent([.video(VideoWidget(source: .remote("https://example.com/video.mp4")))])), turnID),
            (Block(.agentContent([.progress("Progress"), .text("Response")])), turnID),
        ]
        let blocks = ChatBlock.project(sources, thinkingActivity: nil, isBusy: false, interaction: nil)
        if blocks.count != 6 {
            failures.append("Thinking, video, progress, response, and footer must remain separate")
        }
        if blocks.count > 2 {
            if blocks[1].spacingBefore + ChatTranscriptMetrics.thinkingRowHeight < Theme.Size.minimumTouchTarget {
                failures.append("Adjacent thinking hit targets must not overlap")
            }
            if blocks[2].spacingBefore != ChatTranscriptMetrics.blockSpacing {
                failures.append("Video must share rich block spacing")
            }
        }
        return failures
    }
}
#endif
