import Foundation

extension Scenario {
    static let parallelTools = Scenario(name: "parallel") { ctx in
        if ctx.turn == 0 {
            return [
                .say("Fanning out two reads at once.\n"),
                .think("Dispatching two independent reads."),
                execute("console.log({ city: \"SF\", tempF: 64 });"),
                execute("console.log({ city: \"NYC\", tempF: 58 });"),
            ]
        }
        let reads = ctx.resultsText("execute")
        let joined = reads.isEmpty ? "(no reads came back)" : reads.map { "- \($0)" }.joined(separator: "\n")
        return [
            .think("Combining both reads."),
            .wait(.seconds(2)),
            .say("Both reads are back:\n\n\(joined)"),
            .stop(.stop),
        ]
    }

    static let defaultModelSelection = Scenario(name: "default-model-selection") { ctx in
        if ctx.turn == 0 {
            return [execute("""
            const purpose = "Verify and restore new-conversation model preferences";
            const baseline = await ox.app.defaultModel({ purpose });
            const current = await ox.conversation.model({ purpose });
            if (baseline.configured && baseline.provider.id !== "mock") throw Error("Use automatic or Mock defaults for this fixture");
            const original = baseline.configured ? { provider: "mock", model: baseline.model.id, thinkingLevel: baseline.thinkingLevel } : null;
            try {
              const selection = { provider: "mock", model: baseline.model.id === "mock-text-only" ? "mock" : "mock-text-only" };
              const changed = await ox.app.setDefaultModel({ selection, purpose });
              if (!changed.configured || !changed.changed || changed.selection.model !== selection.model) throw Error("Default model selection failed");
              if ((await ox.app.setDefaultModel({ selection, purpose })).changed) throw Error("Default model no-op failed");
              if ((await ox.app.defaultModel({ purpose })).model.id !== selection.model) throw Error("Default model reader failed");
              const automatic = await ox.app.setDefaultModel({ selection: null, purpose });
              if (automatic.configured || automatic.selection !== null || !automatic.changed) throw Error("Automatic reset failed");
              if ((await ox.app.setDefaultModel({ selection: null, purpose })).changed) throw Error("Automatic reset no-op failed");
              for (const setter of [ox.app.setDefaultModel, ox.conversation.setModel]) {
                for (const invalid of [{ provider: "missing-model-qa", model: "mock" }, { provider: "mock", model: "missing-model-qa" }, { provider: "mock", model: "mock", thinkingLevel: "high" }]) {
                  let rejected = false;
                  try { await setter({ selection: invalid, purpose }); } catch { rejected = true; }
                  if (!rejected) throw Error("Invalid model selection was accepted");
                }
              }
              const unchanged = await ox.conversation.model({ purpose });
              if (unchanged.model.id !== current.model.id) throw Error("Default changes affected the current conversation");
              const noop = await ox.conversation.setModel({ selection: { provider: current.provider.id, model: current.model.id }, purpose });
              if (noop.changed || noop.status !== "applied") throw Error("Current model no-op failed");
            } finally {
              await ox.app.setDefaultModel({ selection: original, purpose });
            }
            const restored = await ox.app.defaultModel({ purpose });
            if (restored.configured !== baseline.configured || restored.provider.id !== baseline.provider.id || restored.model.id !== baseline.model.id || restored.thinkingLevel !== baseline.thinkingLevel) throw Error("Default model restoration failed");
            console.log("DEFAULT_MODEL_VERIFIED_AND_RESTORED");
            """)]
        }
        if ctx.resultsText("execute").contains(where: { $0.contains("DEFAULT_MODEL_VERIFIED_AND_RESTORED") }) {
            return [.say("Default model preferences were verified and restored."), .stop(.stop)]
        }
        return [.fail(message: "Default model selection assertions failed", reason: .error)]
    }

    static let modelSelectionChange = Scenario(name: "model-selection") { ctx in
        if ctx.turn == 0 {
            return [execute("""
            const purpose = "Verify requested model changes";
            const before = await ox.conversation.model({ purpose });
            if (before.provider.id !== "mock") throw Error("Native Mock is required");
            const selection = { provider: "mock", model: before.model.id === "mock" ? "mock-text-only" : "mock" };
            const requested = await ox.conversation.setModel({ selection, purpose });
            const duplicate = await ox.conversation.setModel({ selection, purpose });
            const during = await ox.conversation.model({ purpose });
            if (requested.status !== "pending" || !requested.changed || duplicate.changed || duplicate.status !== "pending") throw Error("Pending/no-op contract failed");
            if (during.model.id !== before.model.id || during.change.status !== "pending" || during.change.selection.model !== selection.model) throw Error("Current submission changed its model");
            console.log("MODEL_CHANGE_STAGED", JSON.stringify({ before: before.model.id, target: selection.model, during }));
            """)]
        }
        guard ctx.resultsText("execute").contains(where: { $0.contains("MODEL_CHANGE_STAGED") }) else {
            return [.fail(message: "Model selection assertions failed", reason: .error)]
        }
        if ctx.latestUserSaid("23 error") {
            return [.fail(message: "mock model-switch submission failure", reason: .error)]
        }
        return [
            .think("This submission keeps its original model while the next selection is pending."),
            .wait(.seconds(8)),
            .say("This turn kept its original model. The next turn can use the requested selection."),
            .stop(.stop),
        ]
    }

    static let binaryChoiceFlow = Scenario(name: "binary-choice") { ctx in
        guard let result = ctx.resultText("execute") else {
            return [
                .say("This will permanently delete 3 archived conversations.\n"),
                execute("console.log({ choice: await ox.user.choose({ body: \"Delete 3 archived conversations? This can't be undone.\", options: [\"Yes\", \"No\"], purpose: \"Confirm deletion\" }) });"),
            ]
        }
        if result.contains("\"choice\":\"Yes\"") {
            return [.say("Done — 3 archived conversations deleted."), .stop(.stop)]
        }
        return [.say("Cancelled — nothing was deleted."), .stop(.stop)]
    }

    static let choiceFlow = Scenario(name: "choice") { ctx in
        guard let pick = ctx.resultText("execute") else {
            return [
                .say(
                    String(repeating: "This plan comparison includes the context needed to make an informed choice. ", count: 11)
                        + "\n\nWhich plan should I set you up with?\n"
                ),
                execute("console.log(await ox.user.choose({ body: \"Pick a plan:\", options: [\"Free\", \"Pro\", \"Team\"], purpose: \"Choose a plan\" }));"),
            ]
        }
        return [
            .think("Checking the selected plan."),
            .wait(.seconds(1)),
            .say("Great — setting you up on the **\(pick)** plan."),
            .stop(.stop),
        ]
    }.pacing(betweenDeltas: .milliseconds(1))

    static let virtualMachineCancellation = Scenario(name: "virtual-machine-cancel", steps: [
        .say("Waiting inside JavaScript…\n"),
        execute("await new Promise(() => {});"),
    ])

    static let truncatedToolCall = Scenario(name: "truncated-tool") { ctx in
        if ctx.turn == 0 {
            return [
                .say("Attempting an incomplete tool call…\n"),
                execute("console.log(\"TRUNCATED_TOOL_EXECUTED\");"),
                .stop(.length),
            ]
        }
        let result = ctx.resultText("execute") ?? ""
        if result.contains("was not executed"), result.contains("output token limit") {
            return [.say("Truncated tool call was blocked before execution."), .stop(.stop)]
        }
        return [.say("Truncated tool safety check failed: \(result)"), .stop(.stop)]
    }

    static let pendingStopReason = Scenario(name: "pending-stop", steps: [
        .say("This response must not settle successfully."),
        .stop(.pending),
    ])

    static let compaction = Scenario(name: "compaction") { ctx in
        if ctx.turn == 0 {
            return [
                execute("""
                await ox.fs.read({ path: "skills/visualize/SKILL.md", purpose: "Activate skill before compaction" });
                console.log("EARLY_STEP_" + "A".repeat(50000));
                """),
            ]
        }
        if ctx.userSaid("SPLIT_TURN_CHECKPOINT") || ctx.userSaid("SPLIT_TURN_REPEATED") {
            var pending: Set<String> = []
            var skillRestored = false
            for message in ctx.messages {
                switch message {
                case .user:
                    if !pending.isEmpty { return [.say("Compaction orphaned tool calls."), .stop(.stop)] }
                case .assistant(let assistant):
                    if !pending.isEmpty { return [.say("Compaction separated tool calls and results."), .stop(.stop)] }
                    pending = Set(assistant.content.toolCalls.map(\.id))
                case .toolResult(let result):
                    guard pending.remove(result.toolCallId) != nil else { return [.say("Compaction orphaned a tool result."), .stop(.stop)] }
                    if result.content.concatenatedText.hasPrefix("EARLY_STEP_") { return [.say("Compaction retained the early tool result."), .stop(.stop)] }
                    skillRestored = skillRestored || result.activatedSkills.contains { $0.path == "skills/visualize/SKILL.md" }
                case .system:
                    break
                }
            }
            guard pending.isEmpty, skillRestored, ctx.resultText("execute")?.contains("RECENT_STEP_") == true else {
                return [.say("Compaction lost recent work or activated skills."), .stop(.stop)]
            }
            if ctx.userSaid("SPLIT_TURN_REPEATED") {
                return [.say("Repeated split-turn compaction preserved recent work, tool pairs, and activated skills."), .stop(.stop)]
            }
            return [
                execute("console.log(\"SECOND_RECENT_STEP_\" + \"C\".repeat(50000));"),
                .usage(input: 900_000, output: 32),
            ]
        }
        if ctx.turn == 1 {
            return [
                execute("console.log(\"RECENT_STEP_\" + \"B\".repeat(50000));"),
                .usage(input: 900_000, output: 32),
            ]
        }
        return [.say("The long ongoing turn was not compacted."), .stop(.stop)]
    }

    static let compactionSummary = Scenario(name: "compaction-summary") { ctx in
        if ctx.userSaid("SPLIT_TURN_CHECKPOINT") {
            return [.say("<intent>29</intent> SPLIT_TURN_REPEATED: Earlier progress was summarized again; verify the retained recent step and activated skill."), .stop(.stop)]
        }
        if ctx.latestUserSaid("EARLY_STEP_") {
            return [.say("<intent>29</intent> SPLIT_TURN_CHECKPOINT: The original request is to verify split-turn compaction. The early step completed; recent work is retained separately."), .stop(.stop)]
        }
        return [.say("Earlier conversation state was summarized for the retained turn."), .stop(.stop)]
    }
}
