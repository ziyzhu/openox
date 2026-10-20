import SwiftUI

struct ConversationBlock: Identifiable, Equatable {
    enum ResponseFooterPhase: Equatable {
        case streaming
        case settled

        var isVisible: Bool { self == .settled }
    }

    enum Kind: Equatable {
        case userText(String, attachments: [FileItem])
        case userSkill(UserSkillInvocation, attachments: [FileItem])
        case agentContent(ContentItem)
        case startedConversation(UUID, title: String)
        case thinking(ThinkingTrace)
        case contextCompaction(ContextCompaction)
        case serviceControl(ServiceControl, interactionID: UUID?)
        case responseFooter(text: String, phase: ResponseFooterPhase)
    }

    let id: UUID
    let sourceBlockID: UUID
    let createdAt: Date
    let kind: Kind
    let spacingBefore: CGFloat
    var sourceInvocations: [Invocation] = []
    var isLiveThinking = false

    var isUserInitiated: Bool {
        switch kind {
        case .userText, .userSkill: true
        case .agentContent, .startedConversation, .thinking, .contextCompaction, .serviceControl, .responseFooter: false
        }
    }

    var isResponseFooter: Bool {
        if case .responseFooter = kind { return true }
        return false
    }

    var isThinking: Bool {
        if case .thinking = kind { return true }
        return false
    }

    var isPendingThinking: Bool {
        guard case .thinking(let trace) = kind else { return false }
        return trace.isEmpty && trace.completedAt == nil
    }

    var isActiveInteraction: Bool {
        guard case .serviceControl(_, let interactionID) = kind else { return false }
        return interactionID != nil
    }
}

extension ConversationBlock {
    private typealias ServiceControlLocation = Conversation.PendingServiceControl.Source

    private struct ProjectedTurn {
        let id: TurnID
        var blocks: [ConversationBlock] = []
        var thinkingCount = 0
    }

    static func project(
        _ sources: [(block: Block, turnID: TurnID)],
        thinkingActivity: Conversation.ThinkingActivity?,
        isBusy: Bool,
        interaction: Conversation.Interaction?
    ) -> [ConversationBlock] {
        var projectedTurns: [ProjectedTurn] = []
        let activeTurnID = thinkingActivity?.turnID ?? (isBusy ? sources.last?.turnID : nil)
        let pendingServiceControl: Conversation.PendingServiceControl? = if case .serviceControl(let control) = interaction { control } else { nil }
        let serviceControlLocation = pendingServiceControl.flatMap { pending in
            if let source = pending.source { return source }
            return sources.reversed().compactMap { source -> ServiceControlLocation? in
                guard case .agentContent(let items) = source.block.kind,
                      let itemIndex = items.lastIndex(where: { item in
                          guard case .serviceControl(let control) = item else { return false }
                          return control == pending.control
                      }) else { return nil }
                return ServiceControlLocation(blockID: source.block.id, itemIndex: itemIndex)
            }.first
        }

        for source in sources {
            let block = source.block
            if projectedTurns.last?.id != source.turnID {
                projectedTurns.append(ProjectedTurn(id: source.turnID))
            }
            let turnIndex = projectedTurns.count - 1
            if case .prompt = block.kind { continue }
            if case .thinking(let trace) = block.kind {
                let index = projectedTurns[turnIndex].thinkingCount
                projectedTurns[turnIndex].thinkingCount += 1
                projectedTurns[turnIndex].blocks.append(ConversationBlock(
                    id: thinkingID(turnID: source.turnID, index: index),
                    sourceBlockID: block.id,
                    createdAt: block.createdAt,
                    kind: .thinking(trace),
                    spacingBefore: ConversationTranscriptMetrics.blockSpacing
                ))
                for invocation in trace.invocations {
                    guard invocation.name == Actions.conversationStart,
                          case .succeeded(let result?) = invocation.outcome,
                          let rawID = result.objectValue?["id"]?.stringValue,
                          let conversationID = UUID(uuidString: rawID) else { continue }
                    let title = invocation.args.objectValue?["title"]?.stringValue?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    projectedTurns[turnIndex].blocks.append(ConversationBlock(
                        id: StableID.uuid("conversation.started.\(invocation.id)"),
                        sourceBlockID: block.id,
                        createdAt: block.createdAt,
                        kind: .startedConversation(
                            conversationID,
                            title: title.isEmpty ? L10n.string("New conversation") : title
                        ),
                        spacingBefore: ConversationTranscriptMetrics.blockSpacing
                    ))
                }
                continue
            }
            guard case .agentContent(let items) = block.kind else {
                guard let kind = Self.kind(block.kind) else { continue }
                projectedTurns[turnIndex].blocks.append(ConversationBlock(
                    id: block.id,
                    sourceBlockID: block.id,
                    createdAt: block.createdAt,
                    kind: kind,
                    spacingBefore: ConversationTranscriptMetrics.blockSpacing
                ))
                continue
            }

            let visibleItems = items.enumerated().filter { index, item in
                switch item {
                case .text(let text), .progress(let text):
                    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .serviceControl(let control):
                    if case .signIn = control {
                        return serviceControlLocation == ServiceControlLocation(blockID: block.id, itemIndex: index)
                    }
                    return true
                default:
                    return true
                }
            }
            for (index, item) in visibleItems {
                let id = contentItemID(blockID: block.id, index: index)
                let kind: Kind
                if case .serviceControl(let control) = item {
                    let isActive = serviceControlLocation == ServiceControlLocation(blockID: block.id, itemIndex: index)
                    kind = .serviceControl(control, interactionID: isActive ? pendingServiceControl?.id : nil)
                } else {
                    kind = .agentContent(item)
                }
                projectedTurns[turnIndex].blocks.append(ConversationBlock(
                    id: id,
                    sourceBlockID: block.id,
                    createdAt: block.createdAt,
                    kind: kind,
                    spacingBefore: ConversationTranscriptMetrics.blockSpacing
                ))
            }
            if !visibleItems.isEmpty {
                let text = visibleItems.compactMap { _, item -> String? in
                    guard case .text(let text) = item, !text.isEmpty else { return nil }
                    return text
                }.joined(separator: "\n\n")
                projectedTurns[turnIndex].blocks.append(ConversationBlock(
                    id: StableID.uuid("conversation.block.\(block.id.uuidString).footer"),
                    sourceBlockID: block.id,
                    createdAt: block.createdAt,
                    kind: .responseFooter(
                        text: text,
                        phase: source.turnID == activeTurnID && block.id == sources.last?.block.id ? .streaming : .settled
                    ),
                    spacingBefore: ConversationTranscriptMetrics.responseFooterSpacing
                ))
            }
        }

        if let activity = thinkingActivity {
            let turnIndex: Int
            if let existing = projectedTurns.lastIndex(where: { $0.id == activity.turnID }) {
                turnIndex = existing
            } else {
                projectedTurns.append(ProjectedTurn(id: activity.turnID))
                turnIndex = projectedTurns.count - 1
            }
            if projectedTurns[turnIndex].blocks.last?.isThinking != true {
                let index = projectedTurns[turnIndex].thinkingCount
                let id = thinkingID(turnID: activity.turnID, index: index)
                projectedTurns[turnIndex].blocks.append(ConversationBlock(
                    id: id,
                    sourceBlockID: sources.last?.block.id ?? id,
                    createdAt: activity.startedAt,
                    kind: .thinking(ThinkingTrace(entries: [], completedAt: nil)),
                    spacingBefore: ConversationTranscriptMetrics.blockSpacing
                ))
                projectedTurns[turnIndex].thinkingCount += 1
            }
        }

        let blocks = projectedTurns.flatMap { turn in
            var turnBlocks = turn.blocks
            var invocations: [Invocation] = []
            for index in turnBlocks.indices {
                guard case .thinking(let trace) = turnBlocks[index].kind else { continue }
                let stepInvocations = trace.entries.compactMap { entry -> Invocation? in
                    guard case .invocation(let invocation) = entry else { return nil }
                    return invocation
                }
                turnBlocks[index].sourceInvocations = stepInvocations
                invocations.append(contentsOf: stepInvocations)
            }
            if let lastThinking = turnBlocks.lastIndex(where: \.isThinking) {
                turnBlocks[lastThinking].sourceInvocations = invocations
                turnBlocks[lastThinking].isLiveThinking = thinkingActivity?.turnID == turn.id
            }
            return turnBlocks
        }
        return blocks.enumerated().map { index, block in
            guard index > 0, blocks[index - 1].isThinking, block.isThinking else { return block }
            return ConversationBlock(
                id: block.id,
                sourceBlockID: block.sourceBlockID,
                createdAt: block.createdAt,
                kind: block.kind,
                spacingBefore: max(
                    ConversationTranscriptMetrics.blockSpacing,
                    Theme.Size.minimumTouchTarget - ConversationTranscriptMetrics.thinkingRowHeight
                ),
                sourceInvocations: block.sourceInvocations,
                isLiveThinking: block.isLiveThinking
            )
        }
    }

    static func latestCanvasBlockIDs(in blocks: [Block]) -> [URL: UUID] {
        var latest: [URL: UUID] = [:]
        for block in blocks {
            guard case .agentContent(let items) = block.kind else { continue }
            for (index, item) in items.enumerated() {
                guard case .artifact(let file) = item, file.kind == .html else { continue }
                latest[file.fileURL] = contentItemID(blockID: block.id, index: index)
            }
        }
        return latest
    }

    private static func contentItemID(blockID: UUID, index: Int) -> UUID {
        StableID.uuid("conversation.block.\(blockID.uuidString).item.\(index)")
    }

    private static func thinkingID(turnID: TurnID, index: Int) -> UUID {
        StableID.uuid("conversation.turn.\(turnID.rawValue.uuidString).thinking.\(index)")
    }

    private static func kind(_ kind: Block.Kind) -> Kind? {
        switch kind {
        case .userText(let text, let attachments):
            .userText(text, attachments: attachments)
        case .userSkill(let invocation, let attachments):
            .userSkill(invocation, attachments: attachments)
        case .agentContent:
            nil
        case .prompt:
            nil
        case .thinking(let trace):
            .thinking(trace)
        case .contextCompaction(let compaction):
            .contextCompaction(compaction)
        }
    }
}

struct ConversationTranscriptProjectionSnapshot {
    let key: ConversationTranscriptProjectionKey
    let totalBlockCount: Int
    let sourceRange: Range<Int>
    let sourceBlockIDs: [UUID]
    let blocks: [ConversationBlock]
    let latestCanvasBlockIDs: [URL: UUID]

    init(key: ConversationTranscriptProjectionKey, conversation: Conversation) {
        self.key = key
        let sourceWindow = conversation.blocksWithTurnID(in: key.requestedSourceRange)
        let projectedBlocks = ConversationBlock.project(
            sourceWindow.blocks,
            thinkingActivity: key.thinkingActivity,
            isBusy: key.isBusy,
            interaction: key.interaction
        )
        let requestedOffset = key.requestedSourceRange.lowerBound - sourceWindow.range.lowerBound
        let requestedSourceIDs = sourceWindow.blocks.dropFirst(requestedOffset).map(\.block.id)
        let blocks: [ConversationBlock]
        if requestedOffset > 0 {
            let requestedSourceIDSet = Set(requestedSourceIDs)
            blocks = projectedBlocks.filter {
                requestedSourceIDSet.contains($0.sourceBlockID) || $0.isActiveInteraction
            }
        } else {
            blocks = projectedBlocks
        }
        totalBlockCount = key.totalBlockCount
        sourceRange = key.requestedSourceRange
        sourceBlockIDs = requestedSourceIDs
        self.blocks = blocks
        latestCanvasBlockIDs = ConversationBlock.latestCanvasBlockIDs(in: sourceWindow.blocks.map(\.block))
    }
}

struct ConversationTranscriptProjectionKey: Equatable {
    let conversationID: UUID
    let transcriptRevision: UInt64
    let totalBlockCount: Int
    let requestedSourceRange: Range<Int>
    let thinkingActivity: Conversation.ThinkingActivity?
    let isBusy: Bool
    let interaction: Conversation.Interaction?
}

final class ConversationTranscriptProjectionCache {
    private var snapshot: ConversationTranscriptProjectionSnapshot?

    func snapshot(for key: ConversationTranscriptProjectionKey, conversation: Conversation) -> ConversationTranscriptProjectionSnapshot {
        if let snapshot, snapshot.key == key { return snapshot }
        let resolved = ConversationTranscriptProjectionSnapshot(key: key, conversation: conversation)
        snapshot = resolved
        return resolved
    }
}

struct ConversationTranscriptProjection<Content: View>: View {
    let conversation: Conversation
    let transcriptWindow: TranscriptWindow
    let interaction: Conversation.Interaction?
    let content: (ConversationTranscriptProjectionSnapshot) -> Content

    @State private var cache = ConversationTranscriptProjectionCache()

    var body: some View {
        content(cache.snapshot(for: projectionKey, conversation: conversation))
    }

    private var projectionKey: ConversationTranscriptProjectionKey {
        let totalBlockCount = conversation.transcriptBlockCount
        let requestedSourceRange = transcriptWindow.resolvedRange(total: totalBlockCount)
        return ConversationTranscriptProjectionKey(
            conversationID: conversation.id,
            transcriptRevision: conversation.transcriptRevision,
            totalBlockCount: totalBlockCount,
            requestedSourceRange: requestedSourceRange,
            thinkingActivity: conversation.thinkingActivity,
            isBusy: conversation.isBusy,
            interaction: interaction
        )
    }
}
