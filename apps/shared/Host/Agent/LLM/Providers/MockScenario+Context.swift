import Foundation

extension Scenario {
    static let rateLimited = Scenario(name: "rate-limited", steps: [
        .fail(message: "RESOURCE_EXHAUSTED: exceeded your current quota", reason: .error)
    ])

    static let skillCatalog = Scenario(name: "skill-catalog") { ctx in
        let expectsService = ctx.latestUserSaid("attached")
        let expectsUserSkill = ctx.latestUserSaid("user")
        let verifiesStablePrefix = ctx.latestUserSaid("cache")
        let activatesUserSkill = ctx.latestUserSaid("activate")
        let skills = ctx.section("skills") ?? ""
        let services = ctx.section("attached_services") ?? ""
        let files = ctx.section("conversation_files") ?? ""
        let hasTimestamp = ctx.serializedUserText
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { $0.hasPrefix("[") && $0.hasSuffix(" \(TimeZone.autoupdatingCurrent.identifier)]") }
            == true
        let filePaths = ctx.messages.flatMap { message -> [String] in
            let content = switch message {
            case .system: [ContentBlock]()
            case .user(let value): value.content
            case .assistant(let value): value.content
            case .toolResult(let value): value.content
            }
            return content.compactMap { block in
                guard case .attachment(let file) = block else { return nil }
                return file.virtualPath ?? "<missing file path>"
            }
        }
        guard let languageDirective = try? ModelPromptRenderer.shared.render(.responseDirective, input: AppLocale.resolvedResponseLanguage) else {
            return [.say("Response language could not be rendered."), .stop(.stop)]
        }
        guard skills.contains("<name>grocery-planner</name>") == expectsUserSkill,
              skills.contains("<location>skills/visualize/SKILL.md</location>"),
              languageDirective.isEmpty || ctx.section("language") == languageDirective,
              !skills.contains("127.0.0.1:delayedEcho"),
              !ctx.serializedUserText.contains("<turn-state>"),
              hasTimestamp,
              !verifiesStablePrefix || ctx.hasSystemUpdates,
              filePaths.allSatisfy({ files.contains("`\($0)`") }),
              (services != "No services are attached.") == expectsService else {
            return [.say("Skill catalog context was incorrect."), .stop(.stop)]
        }
        if ctx.latestUserSaid("bundled") {
            guard let result = ctx.toolResults.last else {
                return [execute("""
                const files = await ox.fs.glob({ path: "skills", pattern: "**/SKILL.md", purpose: "Find bundled skills" });
                const guide = await ox.fs.read({ path: "skills/manage-skills/SKILL.md", purpose: "Activate the bundled authoring skill" });
                const references = await ox.fs.list({ path: "skills/manage-skills/references", purpose: "List skill references" });
                console.log({ count: files.paths.length, guide: guide.text.includes("# Manage Skills"), references: references.items.length });
                """)]
            }
            guard !result.isError, result.activatedSkills.contains(where: { $0.name == "manage-skills" }),
                  let text = ctx.resultText("execute"), let values = JSONValue.parse(jsonString: text)?.objectValue,
                  (values["count"]?.intValue ?? 0) >= 5, values["guide"]?.boolValue == true, values["references"]?.intValue == 2 else {
                return [.say("Bundled skill context was incorrect."), .stop(.stop)]
            }
            return [.say("Bundled System skill loaded and activated."), .stop(.stop)]
        }
        if activatesUserSkill {
            guard let result = ctx.toolResults.last else {
                return [execute(#"console.log(await ox.fs.read({ path: "skills/grocery-planner/SKILL.md", purpose: "Activate grocery planning skill" }));"#)]
            }
            guard result.activatedSkills.contains(where: {
                $0.path == "skills/grocery-planner/SKILL.md"
                    && $0.content.contains("organize the grocery list by store section")
            }) else {
                return [.say("User skill activation context was not retained."), .stop(.stop)]
            }
            return [.say("User skill instructions activated."), .stop(.stop)]
        }
        let result = verifiesStablePrefix
            ? "Stable prompt prefix ready."
            : (expectsService ? "Attached skill catalog ready." : "Ox skill catalog ready.")
        return [.say(result), .stop(.stop)]
    }

    static let memoryOnDemand = Scenario(name: "memory-on-demand") { ctx in
        guard !ctx.transientContext.contains("transient-memory-must-not-be-injected") else {
            return [.say("Memory was injected into transient context."), .stop(.stop)]
        }
        if ctx.latestUserSaid("current") {
            guard !ctx.systemPrompt.contains("current-memory-must-be-injected") else {
                return [.say("Current memory replaced the frozen system-prompt snapshot."), .stop(.stop)]
            }
            if ctx.resultText("execute") == nil {
                return [execute(#"console.log(await ox.fs.read({ path: "MEMORY.md", purpose: "Read current memory" }));"#)]
            }
            guard ctx.resultText("execute")?.contains("current-memory-must-be-injected") == true else {
                return [.say("Current memory could not be read on demand."), .stop(.stop)]
            }
            return [.say("Memory stayed frozen in the system prompt and current memory remained available on demand."), .stop(.stop)]
        }
        if ctx.resultText("execute") == nil {
            return [execute(#"console.log(await ox.fs.read({ path: "MEMORY.md", purpose: "Read memory" }));"#)]
        }
        guard ctx.resultText("execute")?.contains("transient-memory-must-not-be-injected") == true else {
            return [.say("Memory could not be read on demand."), .stop(.stop)]
        }
        return [.say("Memory stayed on disk and loaded on demand."), .stop(.stop)]
    }

    static let appInformation = Scenario(name: "app-information") { ctx in
        guard let output = ctx.resultText("execute") else {
            return [execute("""
            const info = JSON.parse((await ox.fs.read({ path: "app/status.json", purpose: "Read app identity" })).text).app;
            const model = await ox.conversation.model({ purpose: "Read current model" });
            console.log({ info, model });
            """)]
        }
        guard ctx.toolResults.last?.isError == false,
              let result = JSONValue.parse(jsonString: output)?.objectValue,
              result["info"]?.objectValue?["name"]?.stringValue == "Ox",
              result["model"]?.objectValue?["model"]?.objectValue?["name"]?.stringValue?.isEmpty == false else {
            return [.say("App information could not be read."), .stop(.stop)]
        }
        return [.say("App information ready: \(output)"), .stop(.stop)]
    }

    static let appLogs = Scenario(name: "app-logs") { ctx in
        guard let output = ctx.resultText("execute") else {
            return [execute("""
            try {
              const result = await ox.fs.grep({ path: "app/logs.jsonl", pattern: '"category":"Session"', options: { literal: true, limit: 3 }, purpose: "Read diagnostic logs" });
              const valid = result.matches.length > 0 && result.matches.length <= 3 && result.matches.every(entry => entry.text.includes('"category":"Session"'));
              console.log(JSON.stringify({ valid, count: result.matches.length, truncated: result.truncated }));
            } catch (error) {
              console.log(JSON.stringify({ error: String(error) }));
            }
            """)]
        }
        guard let result = JSONValue.parse(jsonString: output)?.objectValue else {
            return [.say("App logs returned an invalid result."), .stop(.stop)]
        }
        if result["error"]?.stringValue?.contains("the user declined") == true {
            return [.say("Log access was denied. No logs were returned."), .stop(.stop)]
        }
        guard result["valid"] == .bool(true) else {
            return [.say("App log approval or filtering failed."), .stop(.stop)]
        }
        return [.say("Approved log access returned bounded, filtered diagnostics."), .stop(.stop)]
    }

    static let deferredCompaction = Scenario(name: "deferred-compaction", steps: [
        .say("The final response settled without starting another compaction."),
        .usage(input: 900_000, output: 12),
        .stop(.stop),
    ])

    static let overflowRecovery = Scenario(name: "overflow-recovery") { ctx in
        if ctx.messages.count <= 3 {
            return [.say("Recovered after one context-overflow compaction."), .stop(.stop)]
        }
        return [.say("This reply ran out of context and was cut off mid"), .usage(input: 995_000, output: 4_000), .stop(.length)]
    }

    static let overflowFailure = Scenario(name: "overflow-failure", steps: [
        .fail(message: "maximum context length exceeded after retry", reason: .error),
    ])
}
