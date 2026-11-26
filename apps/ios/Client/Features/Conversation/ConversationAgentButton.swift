import SwiftUI

struct ConversationAgentButton: View {
    struct Parent {
        let title: String?
        let open: () -> Void
    }

    let title: String
    let agent: String?
    var parent: Parent?
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Group {
            if let parent {
                Menu {
                    Button(action: parent.open) {
                        Label(parent.title.map { String(localized: "Open \($0)") } ?? String(localized: "Parent was deleted"),
                              systemImage: "arrow.turn.up.left")
                    }
                    .disabled(parent.title == nil)
                    .accessibilityIdentifier(A11yID.ConversationControls.Children.parent)
                    Button(action: action) {
                        Label("Agent and Model", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier(A11yID.ConversationControls.modelMenuItem)
                } label: {
                    label
                }
            } else {
                Button(action: action) { label }
                    .buttonStyle(.plain)
            }
        }
        .glassEffect(.regular.interactive(), in: Capsule())
        .animation(.smooth, value: title)
        .animation(.smooth, value: subtitle)
        .accessibilityShowsLargeContentViewer {
            Text(verbatim: title)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: accessibilityValue))
        .accessibilityHint(parent == nil ? "Opens agent and model settings" : "Shows the parent conversation and agent settings")
        .accessibilityIdentifier(A11yID.ConversationControls.agentPicker)
    }

    private var label: some View {
        VStack(spacing: 0) {
            Text(verbatim: title)
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.onSurface)
                .contentTransition(.opacity)
            if let subtitle {
                HStack(spacing: Theme.Spacing.xs) {
                    if parent != nil {
                        Image(systemName: "arrow.turn.up.left")
                    }
                    Text(verbatim: subtitle)
                        .contentTransition(.opacity)
                }
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
            }
        }
        .lineLimit(1)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .frame(minHeight: size)
        .contentShape(Capsule())
    }

    private var parentTitle: String? {
        parent.map { $0.title ?? String(localized: "Deleted conversation") }
    }

    private var subtitle: String? {
        let parts = [parentTitle, agent].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var accessibilityValue: String {
        [parentTitle.map { String(localized: "From \($0)") }, agent.map { String(localized: "Agent: \($0)") }]
            .compactMap(\.self)
            .joined(separator: ", ")
    }
}
