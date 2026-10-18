import SwiftUI

struct ScrollToBottomButton: View {
    let composerButtonSize: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(Theme.Colors.onSurface)
                .frame(width: composerButtonSize, height: composerButtonSize)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .minimumTouchTarget()
        .accessibilityLabel(A11yLabel.scrollToBottom)
        .accessibilityIdentifier(A11yID.ConversationControls.scrollToBottom)
    }
}

struct ScrollToBottomControl: View {
    let composer: ConversationComposerModel
    let composerFocused: Bool
    let isEditingMessage: Bool
    let hasFiles: Bool
    let hasAttachedServices: Bool
    let floatsTopStrip: Bool
    let composerButtonSize: CGFloat
    let action: () -> Void

    var body: some View {
        ScrollToBottomButton(composerButtonSize: composerButtonSize, action: action)
            .offset(y: offset)
    }

    private var offset: CGFloat {
        let touchTargetInset = max(0, (Theme.Size.minimumTouchTarget - composerButtonSize) / 2)
        let isResting = !composerFocused && composer.isEmpty && !isEditingMessage
        let showsTopStrip = isEditingMessage || hasFiles || hasAttachedServices
        let firstSurfaceTop = ConversationComposer.firstSurfaceTopOffset(
            isResting: isResting,
            showsTopStrip: showsTopStrip,
            floatsTopStrip: floatsTopStrip
        )
        return firstSurfaceTop - ConversationComposer.surfaceSpacing - composerButtonSize - touchTargetInset
    }
}

struct ConversationPromptCard: View {
    let pending: Conversation.PendingPrompt
    let conversation: Conversation
    let showsLoader: Bool
    let composerButtonSize: CGFloat
    let onCustomFocusChange: (Bool) -> Void

    var body: some View {
        if let request = pending.secretEntry {
            SecretEntryRequestCard(request: request, onSaved: {
                conversation.resolvePrompt(blockId: pending.id, answer: "Saved")
            }, onCancel: {
                conversation.resolvePrompt(blockId: pending.id, answer: "Cancelled")
            })
            .id(request.id)
        } else {
            switch pending.kind {
            case .permission:
                if let request = PermissionRequest(
                    id: pending.id,
                    prompt: pending.prompt,
                    options: pending.options,
                    presentation: pending.permission
                ) {
                    PermissionRequestCard(request: request) { option in
                        conversation.resolvePrompt(blockId: pending.id, answer: option)
                    }
                } else if showsLoader {
                    ActivityBubble()
                }
            case .choice:
                AgentChoiceRequestCard(
                    request: AgentChoiceRequest(
                        id: pending.id,
                        prompt: pending.prompt,
                        options: pending.options,
                        allowsCustomAnswer: pending.allowsCustomAnswer
                    ),
                    composerButtonSize: composerButtonSize,
                    onCustomFocusChange: onCustomFocusChange
                ) { option in
                    conversation.resolvePrompt(blockId: pending.id, answer: option)
                }
            }
        }
    }
}
