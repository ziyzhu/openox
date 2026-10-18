import Foundation

extension Scenario {
    static let progressReport = Scenario(name: "progress-report") { ctx in
        if ctx.turn == 0 {
            return [
                .think("Planning the first pass."),
                execute("""
                await ox.user.progress({ message: "I found the first result. I’m checking the remaining details now.", purpose: "Share progress" });
                console.log(await ox.fs.list({ path: "artifacts", purpose: "List files" }));
                """),
            ]
        }
        return [
            .wait(.seconds(2)),
            .think("Checking the final details after the progress update."),
            .say("The progress update stayed in order."),
            .stop(.stop),
        ]
    }

    static let embeds = Scenario(name: "embeds") { ctx in
        if ctx.turn == 0 {
            return [execute("""
            await ox.fs.write({ path: "weekend-guide.md", content: "# Ocean Beach\\n\\nA windy, open shoreline on San Francisco's west side.", purpose: "Create weekend guide" });
            await ox.fs.write({ path: "trail-times.csv", content: "Trail,Miles,Hours\\nLands End,3.4,1.5\\nMount Sutro,1.2,0.5", purpose: "Create trail times" });
            """)]
        }
        return [.say("Two quiet places, ready to browse.\n\n![Weekend guide](weekend-guide.md)\n\n![Trail times](trail-times.csv)\n\n![Valley lake](https://images.unsplash.com/photo-1470770841072-f978cf4d019e?w=960&h=640&fit=crop)"), .stop(.stop)]
    }

    static let diagrams = Scenario(name: "diagrams") { ctx in
        if ctx.turn == 0 {
            return [execute("""
            await ox.fs.write({ path: "sunrise.svg", content: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 120"><rect width="240" height="120" fill="#FFE8C2"/><circle cx="120" cy="96" r="40" fill="#FFA500"/><rect y="96" width="240" height="24" fill="#3B6EA5"/><script>document.body.innerHTML = "script ran"</script></svg>', purpose: "Create sunrise drawing" });
            """)]
        }
        return [.say("""
        Here is how a request flows, plus the drawing.

        ```mermaid
        flowchart LR
          A[Composer] --> B{Host}
          B -->|tools| C[VM]
          B -->|reply| D[Transcript]
          C --> B
        ```

        ```mermaid
        flowchart TB
          U[You] <--> O["Ox<br/>Conversation and coordination"]
          O <--> S["Ox services<br/>APIs, device actions"]
          O <-->|Delegate and check| M
          subgraph R[Remote machine or server]
            M[MCP bridge] <--> P["Pi Durable<br/>Agent execution"]
            P --> L[Model provider]
            P <--> F["Remote tools<br/>Files, shell"]
          end
        ```

        ![Sunrise](sunrise.svg)
        """), .stop(.stop)]
    }

    static let video = Scenario(name: "video", steps: [
        .say("The video is ready to play.\n\n![Video](widget-video.mp4)"), .stop(.stop),
    ])

    static let signin = Scenario(name: "signin") { ctx in
        if let result = ctx.toolResults.last(where: { $0.toolName == "execute" }) {
            guard !result.isError else { return [.stop(.stop)] }
            return [
                .say("You're in. Top GitHub notification: **ox/services #42 — flaky CI on macOS runners**."),
                .stop(.stop),
            ]
        }
        let domain = "github.com"
        return [
            .say("You'll need to sign in first — use the sign-in card in this conversation.\n"),
            execute("console.log(await ox.service.signIn({ domain: \"\(domain)\", purpose: \"Sign in to service\" }));"),
        ]
    }

    static let botControl = Scenario(name: "bot-control") { ctx in
        if let result = ctx.toolResults.last(where: { $0.toolName == "execute" }) {
            guard !result.isError else { return [.stop(.stop)] }
            return [.say("Verification completed."), .stop(.stop)]
        }
        let domain = "archive.ph"
        return [
            .say("Complete the human-verification card in this conversation.\n"),
            execute("await ox.service.solve({ domain: \"\(domain)\", args: { url: \"https://example.com/\" }, purpose: \"Complete verification\" }); console.log({ verified: true });"),
        ]
    }

    static let payment = Scenario(name: "payment") { ctx in
        if let result = ctx.toolResults.last(where: { $0.toolName == "execute" }) {
            guard !result.isError else { return [.stop(.stop)] }
            return [.say("Checkout completed with reference **fixture-order-42**."), .stop(.stop)]
        }
        #if targetEnvironment(simulator)
        let domain = SimEnv.servicesEndpoint == nil ? "oftendining.com" : "127.0.0.1"
        #else
        let domain = "oftendining.com"
        #endif
        return [
            .say("Review and complete checkout using the payment card in this conversation.\n"),
            execute("console.log(await ox.service.pay({ domain: \"\(domain)\", args: {}, purpose: \"Review checkout\" }));"),
        ]
    }

    static let recover = Scenario(name: "recover") { ctx in
        if ctx.turn == 0 {
            return [
                .say("Trying the primary feed…\n"),
                execute("throw new Error(\"primary feed unavailable\");"),
            ]
        }
        if ctx.turn == 1, ctx.toolResults.last(where: { $0.toolName == "execute" })?.isError == true {
            return [
                .say("Primary feed failed — falling back to the cached mirror.\n"),
                execute("console.log({ source: \"cache\", items: 7 });"),
            ]
        }
        if ctx.turn == 1 {
            return [.say("The failed tool result was not marked as an error."), .stop(.stop)]
        }
        let recovered = ctx.resultText("execute") ?? "n/a"
        return [
            .say("Recovered via the cached mirror: \(recovered)."),
            .stop(.stop),
        ]
    }

    static let fileWorkflow = Scenario(name: "files") { ctx in
        if ctx.turn == 0 {
            return [execute("""
            await ox.fs.write({ path: "artifacts/agent-note.md", content: '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="40"><text x="8" y="26">Hello</text></svg>', purpose: "Create agent note" });
            await ox.fs.edit({ path: "artifacts/agent-note.md", edits: [{ oldText: "Hello", newText: "Hello, Ox!" }], purpose: "Edit agent note" });
            await ox.fs.move({ from: "artifacts/agent-note.md", to: "artifacts/agent-image.svg", purpose: "Rename agent note" });
            console.log((await ox.fs.read({ path: "artifacts/agent-image.svg", purpose: "Read agent image" })).text);
            """)]
        }
        guard ctx.toolResults.last?.isError == false,
              let text = ctx.resultText("execute"), text.contains("Hello, Ox!") else {
            return [.say("The file workflow failed."), .stop(.stop)]
        }
        return [.say("The finished file contains **Hello, Ox!** in agent-image.svg."), .stop(.stop)]
    }

    private static let revenueDocument = #"""
        <style>body{margin:0;padding:24px;font:400 17px/1.45 -apple-system,system-ui,sans-serif;background:#f5f5f5;color:#000000}h1{font:600 22px/1.25 ui-rounded,-apple-system,system-ui,sans-serif}.bars{display:flex;align-items:end;gap:14px;height:280px}.bar{flex:1;min-width:0;background:#f28a2e;border-radius:12px 12px 4px 4px;height:calc(var(--value)*10px);transition:.3s}.bar span{display:block;text-align:center;transform:translateY(-24px);font-family:ui-rounded,-apple-system,system-ui,sans-serif;font-weight:600}button{margin-top:28px;width:100%;min-height:48px;border:0;border-radius:14px;background:#2c2c2e;color:white;font:600 17px/1.45 ui-rounded,-apple-system,system-ui,sans-serif}</style><h1>Quarterly Revenue</h1><div class="bars"><div class="bar" style="--value:10"><span>Q1</span></div><div class="bar" style="--value:15"><span>Q2</span></div><div class="bar" style="--value:12"><span>Q3</span></div><div class="bar" id="q4" data-value="20" style="--value:20"><span>Q4</span></div></div><button id="toggle">Try a projection</button><script>toggle.onclick=()=>{const value=q4.dataset.value==='20'?'24':'20';q4.dataset.value=value;q4.style.setProperty('--value',value);toggle.textContent=value==='24'?'Use actuals':'Try a projection'}</script>
    """#

    static let htmlChart = Scenario(name: "html-chart") { context in
        if context.turn == 0 {
            return [
                .say("Here's the chart you asked for:\n\n"),
                .wait(.seconds(3)),
                execute(htmlFile("revenue", revenueDocument)),
            ]
        }
        return [.say("[Open Quarterly Revenue](sandbox:/mnt/data/mock-revenue.html)"), .stop(.stop)]
    }

    private static func htmlFile(_ id: String, _ document: String) -> String {
        let literal = String(decoding: try! JSONEncoder().encode(document), as: UTF8.self)
        return """
        await ox.fs.write({ path: "artifacts/mock-\(id).html", content: \(literal), purpose: "Create interactive HTML file" });
        """
    }
}
