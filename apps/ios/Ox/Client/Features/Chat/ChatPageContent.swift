import SwiftUI

struct ChatPromptBlock: Equatable {
    let kind: ChatPromptKind
    let prompt: String
    let options: [String]
    let answer: String?
    let resolution: String?
    let allowsCustomAnswer: Bool
    let isActive: Bool
}

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
        case prompt(ChatPromptBlock)
        case serviceControl(ServiceControl, interactionID: UUID)
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
        case .agentContent, .thinking, .contextCompaction, .prompt, .serviceControl, .responseFooter: false
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
        switch kind {
        case .prompt(let prompt): prompt.isActive
        case .serviceControl: true
        case .userText, .userSkill, .agentContent, .thinking, .contextCompaction, .responseFooter: false
        }
    }
}

extension ChatBlock {
    private struct ServiceControlLocation: Equatable {
        let blockID: UUID
        let itemIndex: Int
    }

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
        isBusy: Bool,
        interaction: Chat.Interaction?
    ) -> [ChatBlock] {
        var projectedTurns: [ProjectedTurn] = []
        let pendingPrompt: Chat.PendingPrompt? = if case .prompt(let prompt) = interaction { prompt } else { nil }
        let pendingServiceControl: Chat.PendingServiceControl? = if case .serviceControl(let control) = interaction { control } else { nil }
        let serviceControlLocation = pendingServiceControl.flatMap { pending in
            sources.reversed().compactMap { source -> ServiceControlLocation? in
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
            if case let .prompt(kind, prompt, options, answer, resolution) = block.kind {
                let activePrompt = pendingPrompt?.id == block.id ? pendingPrompt : nil
                projectedTurns[turnIndex].blocks.append(ChatBlock(
                    id: block.id,
                    sourceBlockID: block.id,
                    createdAt: block.createdAt,
                    kind: .prompt(ChatPromptBlock(
                        kind: kind,
                        prompt: prompt,
                        options: options,
                        answer: answer,
                        resolution: resolution,
                        allowsCustomAnswer: activePrompt?.allowsCustomAnswer ?? false,
                        isActive: activePrompt != nil
                    )),
                    spacingBefore: Self.spacingBefore(block.kind)
                ))
                continue
            }
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

            let visibleItems = items.enumerated().filter { index, item in
                guard case .serviceControl = item else { return true }
                return serviceControlLocation == ServiceControlLocation(blockID: block.id, itemIndex: index)
            }
            if !visibleItems.isEmpty {
                projectedTurns[turnIndex].footerSourceBlockID = block.id
                projectedTurns[turnIndex].footerCreatedAt = block.createdAt
                projectedTurns[turnIndex].footerText += visibleItems.compactMap { _, item -> String? in
                    guard case .text(let text) = item, !text.isEmpty else { return nil }
                    return text
                }
            }
            for (position, element) in visibleItems.enumerated() {
                let (index, item) = element
                let id = StableID.uuid("chat.block.\(block.id.uuidString).item.\(index)")
                let spacing = position == 0 ? Self.spacingBefore(block.kind) : Self.spacingBefore(item)
                let kind: Kind
                if case .serviceControl(let control) = item, let pendingServiceControl {
                    kind = .serviceControl(control, interactionID: pendingServiceControl.id)
                } else {
                    kind = .agentContent(item)
                }
                projectedTurns[turnIndex].blocks.append(ChatBlock(
                    id: id,
                    sourceBlockID: block.id,
                    createdAt: block.createdAt,
                    kind: kind,
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
        case .video: Theme.Spacing.xs
        case .text, .progress, .serviceControl, .serviceInspector, .shoveler, .artifact, .skill:
            MarkdownText.blockSpacing
        }
    }
}
