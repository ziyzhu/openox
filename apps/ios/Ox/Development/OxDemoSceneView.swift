#if DEBUG
import SwiftUI
import UIKit

/// Uses production components only. Playback configuration lives outside the rendered UI.
struct OxDemoSceneView: View {
    @State private var playback: OxDemoPlayback
    @State private var editDraft = AttributedString()
    @FocusState private var composerFocused: Bool
    @ScaledMetric(relativeTo: .title3) private var iconButtonSize: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var composerButtonSize: CGFloat = 34
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let autoplay: Bool

    init(scene: OxDemoScene = .connect, completed: Bool = false, autoplay: Bool = false) {
        _playback = State(initialValue: OxDemoPlayback(scene: scene, completed: completed))
        self.autoplay = autoplay
    }

    var body: some View {
        stage
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Colors.background, ignoresSafeAreaEdges: .all)
            .environment(playback.services)
            .environment(\.localDomainArtwork, playback.artwork)
            .environment(\.locale, Locale(identifier: "en"))
            .environment(\.openURL, OpenURLAction { _ in .discarded })
            .themed()
            .onChange(of: playback.focusComposer) { _, focused in composerFocused = focused }
            .onDisappear { playback.stop() }
            .task {
                guard autoplay else { return }
                playback.play(reduceMotion: reduceMotion)
            }
    }

    @ViewBuilder
    private var stage: some View {
        if playback.scene.isHeading {
            OnboardingDisclosureRow(
                symbol: playback.scene.chapter.symbol,
                title: LocalizedStringKey(playback.scene.chapter.rawValue),
                description: LocalizedStringKey(playback.scene.chapter.description)
            )
            .padding(Theme.Spacing.xxl)
            .accessibilityIdentifier("demo.chapter")
            .id(playback.scene)
            .transition(.opacity)
        } else if playback.scene == .providers {
            providerList
                .transition(.opacity)
        } else {
            chat
                .id(playback.scene)
                .transition(.opacity)
        }
    }

    private var chat: some View {
        VStack(spacing: 0) {
            ConversationHeader(
                modelTitle: playback.sent ? nil : "GPT-6 Sol · Fast",
                iconButtonSize: iconButtonSize,
                onShowSidebar: {},
                onPickModel: { playback.select(.providers) }
            ) {
                if playback.sent {
                    ConversationOverflowMenu(size: iconButtonSize) {
                        Button { playback.select(.providers) } label: {
                            Label("Models", systemImage: "slider.horizontal.3")
                        }
                    }
                } else {
                    TemporaryChatButton(isActive: false, size: iconButtonSize, action: {})
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: ConversationTranscriptMetrics.blockSpacing) {
                    if playback.sent {
                        HStack {
                            Spacer(minLength: 40)
                            UserBubble(
                                text: playback.scene.prompt,
                                attachments: [],
                                sourcePrefix: "demo",
                                onOpenAttachment: { _, _ in }
                            )
                            .accessibilityIdentifier(A11yID.Chat.Message.user)
                        }
                    }
                    if let thinking = playback.thinking {
                        ThinkingRow(
                            trace: thinking,
                            sourceInvocations: [],
                            startedAt: playback.thinkingStartedAt,
                            isLive: thinking.completedAt == nil
                        )
                        .padding(.horizontal, 4)
                        .accessibilityIdentifier("demo.thinking")
                    } else if playback.isStreaming && playback.reply.isEmpty {
                        ActivityBubble()
                    }
                    if !playback.reply.isEmpty {
                        VStack(alignment: .leading, spacing: ConversationTranscriptMetrics.responseFooterSpacing) {
                            StreamingMarkdownText(source: playback.reply, isStreaming: playback.isStreaming)
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel(playback.reply, isEnabled: !playback.isStreaming)
                                .accessibilityIdentifier("demo.reply")
                            ResponseFooterBlockView(
                                id: playback.sessionID,
                                text: playback.reply,
                                isVisible: !playback.isStreaming,
                                controls: MessageControls(
                                    onCopy: { UIPasteboard.general.string = $0 },
                                    isCopied: false,
                                    canMutate: false,
                                    onBranch: {},
                                    onRetry: {},
                                    onEdit: {}
                                )
                            )
                        }
                    }
                }
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
    }

    private var composer: some View {
        ConversationComposer(
            composer: playback.composer,
            isEditingMessage: false,
            editDraft: $editDraft,
            speech: playback.speech,
            attachedServices: playback.attachedServices,
            chatArtifacts: [],
            fieldFocused: $composerFocused,
            isFieldFocused: composerFocused,
            sessionID: playback.sessionID,
            isChatEmpty: false,
            isTemporary: false,
            isBusy: playback.isStreaming,
            followIntents: [],
            floatsTopStrip: !playback.attachedServices.isEmpty,
            isEmbedded: false,
            iconButtonSize: iconButtonSize,
            composerButtonSize: composerButtonSize,
            onOpenAttachment: { _, _ in },
            onOpenChatArtifact: { _ in },
            onPasteImages: { _ in },
            onOpenService: { _ in },
            onRemoveService: { _ in },
            onAttachmentChoice: { _ in },
            onServices: {},
            onSubmitSkill: { _, _ in },
            onPreparationIntent: { _ in },
            onCancelEdit: {},
            onSend: { playback.showCompletedScene() },
            onStop: { playback.stop() },
            onSpeechBegin: { _ in },
            serviceAuthSource: .snapshot
        )
    }

    private var providerList: some View {
        NavigationStack {
            SettingsSelectionPickerView(
                title: "Provider",
                options: providerOptions,
                selection: Binding(get: { playback.selectedProvider }, set: { playback.selectedProvider = $0 })
            )
        }
    }

    private var providerOptions: [SettingsSelectionOption<String?>] {
        let providers = [
            ("chatgpt", "ChatGPT", "chatgpt.com"),
            ("claude-subscription", "Claude Pro/Max", "claude.ai"),
            ("github-copilot", "GitHub Copilot", "github.com"),
            ("kimi-coding", "Kimi For Coding", "www.kimi.com"),
            ("claude-web", "Claude Web", "claude.ai"),
            ("doubao-web", "Doubao Web", "doubao.com"),
            ("gemini-web", "Gemini Web", "gemini.google.com"),
            ("grok-web", "Grok Web", "grok.com"),
            ("manus-web", "Manus Web", "manus.im"),
            ("qwen-web", "Qwen Web", "qwen.ai"),
        ]
        return providers.map { id, title, domain in
            SettingsSelectionOption(
                id: id, value: Optional(id), title: title, faviconDomain: domain,
                accessibilityIdentifier: "demo.provider.\(id)"
            )
        } + [
            SettingsSelectionOption(
                id: "api", value: nil, title: "API provider", systemImage: "plus",
                accessibilityIdentifier: "demo.provider.api",
                children: ["OpenAI", "Anthropic", "Gemini", "DeepSeek", "OpenRouter"].map { name in
                    SettingsSelectionOption(
                        id: name, value: Optional(name), title: name, systemImage: "network",
                        accessibilityIdentifier: "demo.provider.api.\(name)"
                    )
                }
            ),
            SettingsSelectionOption(
                id: "custom", value: nil, title: "Custom provider", systemImage: "plus",
                accessibilityIdentifier: "demo.provider.custom"
            ),
        ]
    }
}

#Preview("Storyboard · native UI") {
    OxDemoSceneView(autoplay: true)
}

#Preview("Connect anything") {
    OxDemoSceneView()
}

#Preview("Memory import") {
    OxDemoSceneView(scene: .memory, completed: true)
}

#Preview("Research · composer") {
    OxDemoSceneView(scene: .research, completed: true)
}

#Preview("Local first · stored messages") {
    OxDemoSceneView(scene: .offline, completed: true)
}

#Preview("Yours · providers") {
    OxDemoSceneView(scene: .providers)
}

#Preview("Reddit · reusable service") {
    OxDemoSceneView(scene: .reddit, completed: true)
}
#endif
