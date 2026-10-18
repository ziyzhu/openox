import SwiftUI

private struct EmptyConversationMark: View {
    private let strongCells: Set<Int> = [0, 3, 4, 5, 6, 7, 9, 10, 13, 14]

    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { column in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(color(at: row * 4 + column))
                            .frame(width: 8, height: 8)
                    }
                }
            }
        }
    }

    private func color(at index: Int) -> Color {
        strongCells.contains(index)
            ? Theme.Colors.primary.dynamic
            : .clear
    }
}

struct ConversationEmptyState: View {
    let isModelConfigured: Bool
    let isTemporary: Bool
    let layout: ConversationViewportLayout
    let onChooseModel: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if !isModelConfigured {
            modelSetupState
        } else if isTemporary {
            temporaryEmptyState
        } else {
            persistedEmptyState
        }
    }

    private var modelSetupState: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Text("Choose a default model to start a conversation.")
                .font(Theme.Fonts.headline)
                .foregroundStyle(Theme.Colors.onSurface)
                .multilineTextAlignment(.center)
            Button("Choose default model", action: onChooseModel)
                .font(Theme.Fonts.labelMd)
                .buttonStyle(.borderedProminent)
                .tint(Theme.Colors.primary)
                .accessibilityIdentifier(A11yID.ConversationControls.modelSetup)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .frame(maxWidth: .infinity, minHeight: layout.contentFloorHeight, alignment: .center)
    }

    private var persistedEmptyState: some View {
        EmptyConversationMark()
            .saturation(colorScheme == .dark ? 0 : 0.25)
            .opacity(0.3)
            .frame(width: 40, height: 40)
            .padding(.horizontal, Theme.Spacing.xl)
            .frame(maxWidth: .infinity, minHeight: layout.contentFloorHeight, alignment: .center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("New conversation")
            .accessibilityIdentifier(A11yID.ConversationControls.persistedEmpty)
    }

    private var temporaryEmptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Text("Temporary conversation")
                .font(Theme.Fonts.headline)
                .foregroundStyle(Theme.Colors.onSurface)
            Text("This conversation won’t be saved by Ox or synced with iCloud. Temporary mode changes Ox’s storage only; your selected model’s data policy still applies.")
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.conversationSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .frame(maxWidth: .infinity, minHeight: layout.contentFloorHeight, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(A11yID.ConversationControls.temporaryEmpty)
    }
}
