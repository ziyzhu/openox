import SwiftUI

struct ChatBlock: Identifiable, Equatable {
    enum ResponseFooterPhase: Equatable {
        case streaming
        case settled

        var isVisible: Bool { self == .settled }
    }

    enum Kind: Equatable {
        case userText(String, attachments: [Artifact])
        case userSkill(UserSkillInvocation, attachments: [Artifact])
        case agentContent(ContentItem)
        case thinking(ThinkingTrace)
        case contextCompaction(ContextCompaction)
        case responseFooter(text: String, phase: ResponseFooterPhase)
    }

    let id: UUID
    let sourceBlockID: UUID
    let createdAt: Date
    let kind: Kind
    let spacingBefore: CGFloat

    var isUserInitiated: Bool {
        switch kind {
        case .userText, .userSkill: true
        case .agentContent, .thinking, .contextCompaction, .responseFooter: false
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
}

extension ChatBlock {
    private struct ProjectedTurn {
        let id: TurnID
        var blocks: [ChatBlock] = []
        var thinkingCount = 0
        var footerSourceBlockID: UUID? = nil
        var footerCreatedAt: Date? = nil
        var footerText: [String] = []
    }

    static func project(
        _ sources: [(block: Block, turnID: TurnID)],
        thinkingActivity: Chat.ThinkingActivity?,
        isBusy: Bool
    ) -> [ChatBlock] {
        var projectedTurns: [ProjectedTurn] = []

        for source in sources {
            let block = source.block
            if case .prompt = block.kind { continue }
            if projectedTurns.last?.id != source.turnID {
                projectedTurns.append(ProjectedTurn(id: source.turnID))
            }
            let turnIndex = projectedTurns.count - 1
            if case .thinking(let trace) = block.kind {
                let index = projectedTurns[turnIndex].thinkingCount
                projectedTurns[turnIndex].thinkingCount += 1
                projectedTurns[turnIndex].blocks.append(ChatBlock(
                    id: thinkingID(turnID: source.turnID, index: index),
                    sourceBlockID: block.id,
                    createdAt: block.createdAt,
                    kind: .thinking(trace),
                    spacingBefore: Self.spacingBefore(block.kind)
                ))
                continue
            }
            guard case .agentContent(let items) = block.kind else {
                guard let kind = Self.kind(block.kind) else { continue }
                projectedTurns[turnIndex].blocks.append(ChatBlock(
                    id: block.id,
                    sourceBlockID: block.id,
                    createdAt: block.createdAt,
                    kind: kind,
                    spacingBefore: Self.spacingBefore(block.kind)
                ))
                continue
            }

            let visibleItems = items.filter {
                if case .serviceControl = $0 { return false }
                return true
            }
            if !visibleItems.isEmpty {
                projectedTurns[turnIndex].footerSourceBlockID = block.id
                projectedTurns[turnIndex].footerCreatedAt = block.createdAt
                projectedTurns[turnIndex].footerText += visibleItems.compactMap { item -> String? in
                    guard case .text(let text) = item, !text.isEmpty else { return nil }
                    return text
                }
            }
            for (index, item) in visibleItems.enumerated() {
                let id = StableID.uuid("chat.block.\(block.id.uuidString).item.\(index)")
                let spacing = index == 0 ? Self.spacingBefore(block.kind) : Self.spacingBefore(item)
                projectedTurns[turnIndex].blocks.append(ChatBlock(
                    id: id,
                    sourceBlockID: block.id,
                    createdAt: block.createdAt,
                    kind: .agentContent(item),
                    spacingBefore: spacing
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
                projectedTurns[turnIndex].blocks.append(ChatBlock(
                    id: id,
                    sourceBlockID: sources.last?.block.id ?? id,
                    createdAt: activity.startedAt,
                    kind: .thinking(ThinkingTrace(entries: [], completedAt: nil)),
                    spacingBefore: MarkdownText.blockSpacing
                ))
                projectedTurns[turnIndex].thinkingCount += 1
            }
        }

        let activeTurnID = thinkingActivity?.turnID ?? (isBusy ? sources.last?.turnID : nil)
        let blocks = projectedTurns.flatMap { turn in
            guard let sourceBlockID = turn.footerSourceBlockID,
                  let createdAt = turn.footerCreatedAt else { return turn.blocks }
            let text = turn.footerText.joined(separator: "\n\n")
            guard !text.isEmpty else { return turn.blocks }
            return turn.blocks + [ChatBlock(
                id: StableID.uuid("chat.turn.\(turn.id.rawValue.uuidString).footer"),
                sourceBlockID: sourceBlockID,
                createdAt: createdAt,
                kind: .responseFooter(
                    text: text,
                    phase: turn.id == activeTurnID ? .streaming : .settled
                ),
                spacingBefore: MarkdownText.responseFooterSpacing
            )]
        }
        return blocks.enumerated().map { index, block in
            guard index > 0, blocks[index - 1].isThinking, block.isThinking else { return block }
            return ChatBlock(
                id: block.id,
                sourceBlockID: block.sourceBlockID,
                createdAt: block.createdAt,
                kind: block.kind,
                spacingBefore: 0
            )
        }
    }

    private static func thinkingID(turnID: TurnID, index: Int) -> UUID {
        StableID.uuid("chat.turn.\(turnID.rawValue.uuidString).thinking.\(index)")
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

    private static func spacingBefore(_ kind: Block.Kind) -> CGFloat {
        guard case .agentContent(let items) = kind, let first = items.first else {
            return MarkdownText.blockSpacing
        }
        return spacingBefore(first)
    }

    private static func spacingBefore(_ item: ContentItem) -> CGFloat {
        switch item {
        case .serviceInspector, .shoveler, .video, .artifact, .skill: Theme.Spacing.xs
        case .text, .progress, .serviceControl: MarkdownText.blockSpacing
        }
    }
}

struct ChatDock: Identifiable, Equatable {
    enum Acknowledgement: Identifiable, Equatable {
        case permission(PermissionAcknowledgement)
        case choice(ChoiceAcknowledgement)

        var id: UUID {
            switch self {
            case .permission(let acknowledgement): acknowledgement.id
            case .choice(let acknowledgement): acknowledgement.id
            }
        }
    }

    enum Kind: Equatable {
        case permission(PermissionRequest)
        case choice(AgentChoiceRequest)
        case serviceControl(Chat.PendingServiceControl)
        case permissionAcknowledgement(PermissionAcknowledgement)
        case choiceAcknowledgement(ChoiceAcknowledgement)
        case composer
    }

    let id: UUID
    let kind: Kind

    @MainActor
    static func project(
        interaction: Chat.Interaction?,
        acknowledgement: Acknowledgement?
    ) -> ChatDock {
        switch acknowledgement {
        case .permission(let acknowledgement):
            return ChatDock(id: acknowledgement.id, kind: .permissionAcknowledgement(acknowledgement))
        case .choice(let acknowledgement):
            return ChatDock(id: acknowledgement.id, kind: .choiceAcknowledgement(acknowledgement))
        case nil:
            break
        }
        switch interaction {
        case .prompt(let prompt):
            if let permission = PermissionRequest(prompt) {
                return ChatDock(id: permission.id, kind: .permission(permission))
            }
            if let choice = AgentChoiceRequest(prompt) {
                return ChatDock(id: choice.id, kind: .choice(choice))
            }
        case .serviceControl(let control):
            return ChatDock(id: control.id, kind: .serviceControl(control))
        case nil:
            break
        }
        return ChatDock(id: StableID.uuid("chat.dock.composer"), kind: .composer)
    }
}
