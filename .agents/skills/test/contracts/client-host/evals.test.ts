import { expect, test } from "bun:test";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ROOT } from "../../../../lib.ts";
import { RPC_VERSION, validateParams, validateResult } from "../../../../../packages/protocol/src/index.ts";
import type { Assertion, CaseBinding, EvalBlock, EvalMessage, Fixture, Report } from "../../../evals/scripts/types.ts";

type Scenario = "pass" | "fake" | "expected-error" | "unexpected-error" | "approval" | "missing" | "truncated" | "collateral" | "busy" | "provider-error" | "timeout" | "probe-wrong" | "cleanup-error" | "forged-guide" | "wrong-skill" | "ambiguous-reference";
type Conversation = { messages: EvalMessage[]; blocks: EvalBlock[]; isBusy: boolean; temporary: boolean; pendingPrompt?: { id: string; prompt: string; options: string[]; allowsCustomAnswer: boolean; requiresApp: boolean } };

const readerBinding = (): CaseBinding => ({
  context: "Identify the current active QA Profile without changing anything.",
  observations: { profile: { kind: "vm", name: "ox.app.profile", args: {} }, memory: { kind: "vm", name: "ox.fs.read", args: { path: "MEMORY.md" } } },
  assertions: [
    { evidence: "qa", phase: "before", observation: "profile", path: ["name"], operator: "equals", expected: "EvalQA" },
    { evidence: "outcome", phase: "after", observation: "profile", path: ["name"], operator: "equals", expected: "EvalQA" },
    { evidence: "preserved", phase: "after", observation: "memory", path: ["text"], operator: "unchanged" },
  ],
  actions: [{ name: "ox.app.profile", outcome: "succeeded", minimum: 1, maximum: 1 }], allowedActions: ["ox.app.profile"],
});

const failureBinding = (): CaseBinding => ({
  ...readerBinding(), context: "Read the unavailable run-owned QA file /qa/missing.txt once and report the actual error without modifying anything.",
  observations: { ...readerBinding().observations, missing: { kind: "vm", name: "ox.fs.glob", args: { path: "/qa", pattern: "missing.txt" } } },
  assertions: [
    ...readerBinding().assertions.filter(rule => rule.evidence !== "outcome"),
    { evidence: "condition", phase: "before", observation: "missing", path: ["paths"], operator: "equals", expected: [] },
    { evidence: "outcome", phase: "after", observation: "missing", path: ["paths"], operator: "equals", expected: [] },
  ],
  actions: [{ name: "ox.fs.read", outcome: "failed", minimum: 1, maximum: 1, args: { path: "/qa/missing.txt" } }], allowedActions: ["ox.fs.read"],
});

const skillBinding = (probe = false): CaseBinding => ({
  ...readerBinding(), context: "Create a Profile skill named qa-created. Its accepted instructions return exactly QA_TOKEN_7491. Preserve existing state.",
  ...(probe ? { probeContext: "Use only the Profile skill qa-created." } : {}),
  observations: { ...readerBinding().observations, skill: { kind: "vm", name: "ox.fs.glob", args: { path: "skills/qa-created", pattern: "**/*" } }, package: { kind: "skill", name: "qa-created", phases: ["after"] } },
  assertions: [
    ...readerBinding().assertions.filter(rule => rule.evidence !== "outcome"),
    { evidence: "absent", phase: "before", observation: "skill", path: ["paths"], operator: "equals", expected: [] },
    { evidence: "outcome", phase: "after", observation: "skill", path: ["paths"], operator: "equals", expected: ["skills/qa-created/SKILL.md"] },
    { evidence: "outcome", phase: "after", observation: "package", path: [], operator: "equals", expected: { name: "qa-created", description: "Return a QA verification token.", instructions: "Reply with exactly QA_TOKEN_7491", services: [], resources: {} } },
    { evidence: "cleanup", phase: "cleanup", observation: "skill", path: ["paths"], operator: "unchanged" },
    ...(probe ? [{ evidence: "probe", phase: "probe", observation: "probe", path: ["messages", "2", "assistant", "content", "0", "text", "text"], operator: "equals", expected: "QA_TOKEN_7491" } as Assertion] : []),
  ],
  actions: [{ name: "ox.skill.create", outcome: "succeeded", minimum: 1, maximum: 1, args: { name: "qa-created" } }, { name: "ox.skill.delete", outcome: "succeeded", minimum: 0, maximum: 1, args: { name: "qa-created" } }],
  allowedActions: ["ox.fs.read", "ox.skill.create", "ox.skill.delete", "ox.user.choose"], cleanup: "Delete only the run-owned QA skill qa-created and preserve unrelated state.",
});

const childBinding = (): CaseBinding => ({
  ...readerBinding(), context: "Start a QA child titled qa-child whose self-contained task is to answer 17 plus 25. Inspect its result before reporting completion.",
  observations: { ...readerBinding().observations, child: { kind: "conversation", id: { $receipt: "ox.conversation.start", path: ["id"] }, phases: ["after", "cleanup"] } },
  assertions: [
    ...readerBinding().assertions.filter(rule => rule.evidence !== "outcome"),
    { evidence: "outcome", phase: "after", observation: "child", path: ["messages", "0", "assistant", "content", "0", "text", "text"], operator: "equals", expected: "42" },
    { evidence: "cleanup", phase: "cleanup", observation: "memory", path: ["text"], operator: "unchanged" },
    { evidence: "child-removed", phase: "cleanup", observation: "child", path: [], operator: "equals", expected: null },
  ],
  actions: [{ name: "ox.conversation.start", outcome: "succeeded", minimum: 1, maximum: 1, args: { title: "qa-child" } },
    { name: "ox.conversation.delete", outcome: "succeeded", minimum: 0, maximum: 1, args: { id: { $receipt: "ox.conversation.start", path: ["id"] } } }],
  allowedActions: ["ox.conversation.start", "ox.conversation.delete"], cleanup: "Delete only the run-owned conversation with id {{receipt:ox.conversation.start:id}}. Preserve unrelated state.",
});

async function exercise(scenario: Scenario = "pass") {
  const directory = await mkdtemp(join(tmpdir(), "ox-eval-e2e-"));
  const requests: Array<{ method: string; params: Record<string, any> }> = [];
  const chats = new Map<string, Conversation>();
  const model = { id: "example", providerModelID: "example", displayName: "Example", maxTokens: 1000, maxContext: 10000, supportsTools: true, reasoning: false, reasoningEfforts: [], inputModalities: ["text"], outputModalities: ["text"] };
  const providers = [{ id: "example", displayName: "Example", regions: ["global"], supportsTools: true, reasoningPolicy: "none", credentialID: "example", models: [model] }];
  const files: Record<string, string> = { "MEMORY.md": "Existing memory.", "SOUL.md": "Existing soul." };
  let active = "";
  let serial = 0;
  const snapshot = (id: string) => ({ id, model, systemPrompt: "Controlled transport fixture", renderedSystemPrompt: "Controlled transport fixture", soul: "", memory: "", tools: [{ name: "execute", description: "Fixture tool", parameters: {}, strict: true }], ...chats.get(id) });
  const answer = (chat: Conversation, text: string) => { chat.messages.push({ type: "assistant", assistant: { content: [{ type: "text", text: { text } }], stopReason: "stop" } }); chat.isBusy = false; };
  function executed(chat: Conversation, name: string, args: Record<string, unknown>, text: string, failed = false, value: unknown = text) {
    const id = `tool-${chat.messages.length}`;
    chat.messages.push({ type: "assistant", assistant: { content: [{ type: "toolCall", toolCall: { id, name: "execute", arguments: { source: `console.log(await ${name}(${JSON.stringify(args)}));` } } }], stopReason: "toolUse" } },
      { type: "toolResult", toolResult: { toolCallId: id, toolName: "execute", content: [{ type: "text", text: { text } }], isError: failed } });
    if (scenario !== "fake") chat.blocks.push({ kind: { type: "thinking", trace: { entries: [{ invocation: { name, args, outcome: failed ? { failed: { _0: text } } : { succeeded: { _0: value } } } }], omittedInvocations: scenario === "truncated" ? 1 : 0 } } });
  }
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0,
    fetch(request, server) { if (!server.upgrade(request)) return new Response("WebSocket required", { status: 400 }); },
    websocket: { message(socket, message) {
      const request = JSON.parse(String(message)); requests.push(request);
      const reply = { jsonrpc: "2.0", id: request.id };
      const reject = (message: string): void => { socket.send(JSON.stringify({ ...reply, error: { code: -32000, message } })); };
      if (!validateParams(request.method, request.params ?? {})) return reject("Invalid params");
      const id = request.params.sessionId ?? active;
      const chat = chats.get(id);
      let result: unknown;
      switch (request.method) {
        case "host.describe": result = { implementation: { name: "Eval E2E Host", version: "1", build: "1" }, protocols: { rpc: [RPC_VERSION] }, methods: ["chats.new", "chats.send", "chats.get", "chats.stop", "chats.open", "chats.respond", "logs.list", "providers.list", "vm.call"] }; break;
        case "providers.list": result = { region: "global", providers }; break;
        case "chats.new": active = `qa-${chats.size + 1}`; chats.set(active, { messages: [], blocks: [], isBusy: false, temporary: request.params.temporary === true }); result = { chatId: active, temporary: request.params.temporary === true, model: "example:example" }; break;
        case "chats.get": result = chat ? { data: snapshot(id) } : scenario === "busy" ? { data: { ...snapshot("busy"), messages: [], blocks: [], isBusy: true } } : {}; break;
        case "chats.open": if (!chat || chat.temporary) return reject("Saved QA conversation not found"); active = id; result = { data: snapshot(id) }; break;
        case "chats.send": {
          if (!chat) return reject("Unknown conversation");
          if (scenario === "provider-error") return reject("Provider unavailable");
          if (scenario === "timeout") { chat.isBusy = true; return; }
          const prompt = String(request.params.text);
          if (prompt.startsWith("Delete only")) {
            if (scenario === "cleanup-error") return reject("Cleanup unavailable");
            if (prompt.includes("conversation")) {
              if (!prompt.includes('"child-created"')) return reject("Cleanup did not resolve the actual native ID");
              chats.delete("child-created");
              executed(chat, "ox.conversation.delete", { id: "child-created" }, "Deleted"); answer(chat, "Removed only the QA child.");
            } else {
              delete files["skills/qa-created/SKILL.md"];
              executed(chat, "ox.skill.delete", { name: "qa-created" }, "Deleted"); answer(chat, "Removed only the QA skill.");
            }
          } else if (prompt.startsWith("Start an independent task")) {
            const child: Conversation = { messages: [], blocks: [], isBusy: false, temporary: false };
            answer(child, "42"); chats.set("child-created", child);
            executed(chat, "ox.conversation.start", { title: "qa-child", prompt: "Answer 17 plus 25." }, "Created child", false, { id: "child-created" });
            if (scenario === "ambiguous-reference") executed(chat, "ox.conversation.start", { title: "qa-child", prompt: "Answer 17 plus 25." }, "Created another child", false, { id: "different-child" });
            answer(chat, "The child completed its independent task.");
          } else if (prompt.startsWith("Use the QA skill")) {
            executed(chat, "ox.fs.read", { path: "skills/qa-created/SKILL.md" }, files["skills/qa-created/SKILL.md"]!);
            answer(chat, scenario === "probe-wrong" ? "WRONG" : "QA_TOKEN_7491");
          } else if (prompt.includes("Create the requested reusable") || prompt.includes("Create the requested skill for later")) {
            executed(chat, "ox.fs.read", { path: "skills/manage-skills/SKILL.md" }, scenario === "forged-guide" ? "Invented workflow" : "Actual System guide");
            executed(chat, "ox.fs.read", { path: "skills/manage-skills/references/user-skill.md" }, "Actual System reference");
            chat.pendingPrompt = { id: "checkpoint", prompt: scenario === "approval" ? "Approve native mutation?" : "Review skill proposal", options: scenario === "approval" ? ["Approve", "Deny"] : ["Create skill", "Revise proposal", "Cancel"], allowsCustomAnswer: true, requiresApp: false };
            chat.isBusy = true; result = { chatId: id, outcome: "needsAttention" }; break;
          } else {
            if (scenario === "approval") { chat.pendingPrompt = { id: "native", prompt: "Approve?", options: ["Approve", "Deny"], allowsCustomAnswer: false, requiresApp: false }; chat.isBusy = true; result = { chatId: id, outcome: "needsAttention" }; break; }
            const failed = scenario === "expected-error" || scenario === "unexpected-error";
            executed(chat, failed ? "ox.fs.read" : "ox.app.profile", failed ? { path: "/qa/missing.txt" } : {}, failed ? "QA_FILE_NOT_FOUND" : "EvalQA", failed);
            if (scenario === "collateral") files["MEMORY.md"] = "Unauthorized mutation.";
            answer(chat, failed ? "The requested file is missing." : "The current Profile is EvalQA in local storage.");
          }
          result = { chatId: id, outcome: "completed" }; break;
        }
        case "chats.respond": {
          if (!chat?.pendingPrompt || chat.pendingPrompt.id !== request.params.promptId) return reject("Stale prompt");
          if (request.params.answer !== "Create skill") return reject("Unexpected choice");
          files["skills/qa-created/SKILL.md"] = "---\nname: qa-created\ndescription: Return a QA verification token.\n---\n\nReply with exactly QA_TOKEN_7491\n";
          executed(chat, "ox.user.choose", { options: chat.pendingPrompt.options }, "Create skill");
          executed(chat, "ox.skill.create", { name: scenario === "wrong-skill" ? "unrelated-skill" : "qa-created" }, "Created");
          delete chat.pendingPrompt; answer(chat, "Created the accepted skill."); result = { chatId: id, promptId: request.params.promptId }; break;
        }
        case "chats.stop": if (!chat) return reject("Unknown conversation"); result = { chatId: id, wasRunning: chat.isBusy }; chat.isBusy = false; delete chat.pendingPrompt; break;
        case "vm.call": {
          if (!chat) return reject("Unknown observer");
          const args = request.params.arguments;
          let value: unknown;
          if (scenario === "missing" && request.params.function === "ox.fs.read") { result = {}; break; }
          switch (request.params.function) {
            case "ox.app.profile": value = { name: "EvalQA", storage: "local" }; break;
            case "ox.fs.read": value = { path: args.path, text: args.path === "skills/manage-skills/SKILL.md" ? "Actual System guide" : args.path === "skills/manage-skills/references/user-skill.md" ? "Actual System reference" : files[args.path], truncated: false, unsupported: null }; break;
            case "ox.fs.glob": value = { paths: Object.keys(files).filter(path => path.startsWith(args.path)).sort(), truncated: false }; break;
            default: return reject("Unexpected observation");
          }
          result = { value }; break;
        }
        case "logs.list": result = request.params.cursor ? { logs: [{ seq: 1, time: new Date().toISOString(), level: "error", category: "Other", thread: "", location: "fixture", message: "Unrelated Host error" }], hasMore: false }
          : { logs: [{ seq: 2, time: new Date().toISOString(), level: "info", category: "Agent", thread: "", location: "fixture", message: `chat=${active}` }], hasMore: true, nextCursor: "older" }; break;
        default: return reject(`Unexpected method ${request.method}`);
      }
      if (!validateResult(request.method, result)) return reject(`Invalid fixture result ${request.method}`);
      socket.send(JSON.stringify({ ...reply, result }));
    } },
  });
  async function command(args: string[]) {
    const child = Bun.spawn([process.execPath, "--no-env-file", `${ROOT}/.agents/skills/evals/scripts/runner.ts`, ...args], { cwd: ROOT, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
    return { code, stdout, stderr };
  }
  async function run(id = "app-profile-success", binding: CaseBinding | null = readerBinding(), extra: string[] = []) {
    const output = join(directory, `report-${++serial}.json`);
    const fixturePath = join(directory, `fixture-${serial}.json`);
    const fixture: Fixture = { version: 1, qaProfile: "EvalQA", cases: binding ? { [id]: binding } : {} };
    await writeFile(fixturePath, JSON.stringify(fixture));
    const result = await command(["--host", `ws://127.0.0.1:${server.port}`, "--provider", "example", "--model", "example", "--fixture", fixturePath, "--qa-profile", "EvalQA", "--case", id, "--output", output, ...extra]);
    return { ...result, output, report: await Bun.file(output).exists() ? JSON.parse(await readFile(output, "utf8")) as Report : undefined };
  }
  return { run, command, requests, files, directory, close: async () => { server.stop(true); await rm(directory, { recursive: true, force: true }); } };
}

test("replacement catalog validates complete function and System workflow coverage through its CLI", async () => {
  const fixture = await exercise();
  try {
    const result = await fixture.command(["--validate", "--suite", "all"]);
    expect(result.code).toBe(0); expect(result.stdout).toContain("111 functions and 5 System skills");
    const listed = await fixture.command(["--list", "--suite", "all", "--json"]);
    const cases = JSON.parse(listed.stdout);
    expect(cases).toHaveLength(84);
    expect(cases.filter((entry: { functions?: string[] }) => (entry.functions?.length ?? 0) > 1)).toHaveLength(20);
    expect(cases.some((entry: { id: string }) => entry.id === "brief-answer")).toBe(false);
    expect(cases.every((entry: { evidence: Record<string, string> }) => entry.evidence.outcome && entry.evidence.preserved)).toBe(true);
    const smoke = JSON.parse((await fixture.command(["--list", "--json"])).stdout);
    expect(smoke.map((entry: { id: string }) => entry.id)).toEqual(["app-profile-success", "provider-list-success", "repository-list-success", "schedule-list-success"]);
    expect(smoke.every((entry: { effect: string }) => entry.effect === "read")).toBe(true);
    expect(fixture.requests).toHaveLength(0);
  } finally { await fixture.close(); }
});

test("ordinary CLI attempts collect independent state, isolated repetitions, paginated logs and owner-only reports", async () => {
  const fixture = await exercise();
  try {
    const result = await fixture.run("app-profile-success", readerBinding(), ["--repeat", "2"]);
    expect(result.code, result.stdout + result.stderr).toBe(2); expect(result.report?.results).toHaveLength(2);
    expect(result.report?.results.every(attempt => attempt.status === "unverified" && attempt.checks.every(check => check.passed))).toBe(true);
    expect(new Set(result.report?.results.map(attempt => attempt.response?.chatId)).size).toBe(2);
    expect(result.report?.results[0]?.response?.logs).toHaveLength(2);
    expect((await stat(result.output)).mode & 0o777).toBe(0o600);
    const output = join(fixture.directory, "reviewed.json");
    expect((await fixture.command(["--review", result.output, "--case", "app-profile-success", "--decision", "pass", "--note", "Reviewed actual Profile answer against independent state.", "--output", output])).code).toBe(0);
    expect((await Bun.file(output).json()).results[0].status).toBe("pass");
    const compared = await fixture.command(["compare", result.output, output]);
    expect(compared.code).toBe(2); expect(JSON.parse(compared.stdout)[0].change).toBe("not-comparable");
    expect(fixture.requests.every(request => request.method !== "agents.evaluate")).toBe(true);
  } finally { await fixture.close(); }
}, 30000);

test("expected native failures are graded by actual receipts and independently observed state", async () => {
  const fixture = await exercise("expected-error");
  try {
    const result = await fixture.run("fs-read-failure", failureBinding());
    expect(result.code, result.stdout + result.stderr).toBe(2); expect(result.report?.results[0]?.status).toBe("unverified");
    expect(result.report?.results[0]?.checks.every(check => check.passed)).toBe(true);
    expect(fixture.requests.filter(request => request.method === "chats.send")).toHaveLength(1);
  } finally { await fixture.close(); }
});

for (const scenario of ["fake", "unexpected-error", "missing", "truncated", "collateral", "provider-error", "timeout"] as const) {
  test(`missing receipts, evidence, collateral changes and submission errors cannot pass or be manually overridden: ${scenario}`, async () => {
    const fixture = await exercise(scenario);
    try {
      const result = await fixture.run("app-profile-success", readerBinding(), ["--repeat", "2", "--timeout", "1000"]);
      expect(result.code).toBe(1); expect(result.report?.results).toHaveLength(1);
      expect(["fail", "error"]).toContain(result.report!.results[0]!.status);
      expect((await fixture.command(["--review", result.output, "--case", "app-profile-success", "--decision", "pass", "--note", "Attempted override", "--output", join(fixture.directory, "invalid.json")])).code).toBe(1);
      expect(fixture.requests.filter(request => request.method === "chats.send").length).toBeLessThanOrEqual(1);
      expect(fixture.requests.some(request => request.method === "chats.respond")).toBe(false);
      if (scenario === "collateral") expect(fixture.files["MEMORY.md"]).toBe("Unauthorized mutation.");
    } finally { await fixture.close(); }
  }, 15000);
}

test("unprepared fixtures and incorrect preconditions are blocked before model submission", async () => {
  const fixture = await exercise();
  try {
    const missing = await fixture.run("app-profile-success", null);
    expect(missing.code).toBe(2); expect(missing.report?.results[0]?.status).toBe("blocked");
    expect(fixture.requests).toHaveLength(0);
    const binding = readerBinding(); binding.assertions[0]!.expected = "WrongQA";
    const wrong = await fixture.run("app-profile-success", binding);
    expect(wrong.code).toBe(2); expect(wrong.report?.results[0]?.status).toBe("blocked");
    expect(fixture.requests.some(request => request.method === "chats.send")).toBe(false);
  } finally { await fixture.close(); }
});

test("declared skill choices are distinct from native approvals and complete real creation, probing, and cleanup", async () => {
  const fixture = await exercise();
  try {
    const result = await fixture.run("manage-skills-fresh-use", skillBinding(true), ["--allow-profile-writes", "--allow-choices"]);
    expect(result.code, result.stdout + result.stderr).toBe(2); expect(result.report?.results[0]?.status).toBe("unverified");
    const response = result.report!.results[0]!.response!;
    expect(response.choices[0]?.answer).toBe("Create skill"); expect(response.probe?.chatId).not.toBe(response.chatId);
    expect(response.cleanup?.chatId).toBe(response.chatId);
    expect(response.probe?.initial?.messages).toEqual([]); expect(response.restored?.values.skill).toEqual(response.before?.values.skill);
    expect(fixture.files["skills/qa-created/SKILL.md"]).toBeUndefined();
    const probeRequest = fixture.requests.find(request => request.method === "chats.send" && String(request.params.text).startsWith("Use the QA skill"))!;
    expect(probeRequest.params.text).not.toContain("QA_TOKEN_7491");
    expect(fixture.requests.filter(request => request.method === "chats.respond")).toHaveLength(1);
  } finally { await fixture.close(); }
}, 15000);

for (const scenario of ["approval", "probe-wrong", "cleanup-error", "forged-guide", "wrong-skill"] as const) {
  test(`native gates, failed probes and uncertain cleanup cannot establish coverage: ${scenario}`, async () => {
    const fixture = await exercise(scenario);
    try {
      const result = await fixture.run("manage-skills-fresh-use", skillBinding(true), ["--allow-profile-writes", "--allow-choices"]);
      expect(result.code).toBe(scenario === "approval" ? 2 : 1);
      expect(result.report?.results[0]?.status).toBe(scenario === "approval" ? "blocked" : scenario === "cleanup-error" ? "error" : "fail");
      if (scenario === "approval") expect(fixture.requests.some(request => request.method === "chats.respond")).toBe(false);
    } finally { await fixture.close(); }
  }, 15000);
}

test("write authorization, read-only observer contracts, independent oracles and nonleaking probes are enforced before dispatch", async () => {
  const fixture = await exercise();
  try {
    expect((await fixture.run("manage-skills-create", skillBinding(), ["--allow-choices"])).report?.results[0]?.status).toBe("blocked");
    const bad = readerBinding(); bad.observations.profile = { kind: "vm", name: "ox.fs.write", args: {} };
    expect((await fixture.run("app-profile-success", bad)).code).toBe(1);
    const noOracle = readerBinding(); noOracle.assertions = noOracle.assertions.filter(rule => rule.evidence !== "outcome");
    expect((await fixture.run("app-profile-success", noOracle)).code).toBe(1);
    const leaked = skillBinding(true); leaked.probeContext = "The answer is QA_TOKEN_7491";
    expect((await fixture.run("manage-skills-fresh-use", leaked)).code).toBe(1);
    expect(fixture.requests).toHaveLength(0);
  } finally { await fixture.close(); }
});

test("busy working conversations remain untouched", async () => {
  const fixture = await exercise("busy");
  try {
    const result = await fixture.run(); expect(result.code).toBe(1); expect(result.stderr).toContain("leave it untouched");
    expect(fixture.requests.some(request => ["chats.new", "chats.send", "chats.stop"].includes(request.method))).toBe(false);
  } finally { await fixture.close(); }
});

test("generated IDs are independently observed and cleaned up through unambiguous native receipts", async () => {
  for (const scenario of ["pass", "ambiguous-reference"] as const) {
    const fixture = await exercise(scenario);
    try {
      const result = await fixture.run("conversation-start-success", childBinding(), ["--allow-profile-writes"]);
      expect(result.code, result.stdout + result.stderr).toBe(scenario === "pass" ? 2 : 1);
      expect(result.report?.results[0]?.status).toBe(scenario === "pass" ? "unverified" : "error");
      if (scenario === "pass") {
        expect(result.report?.results[0]?.response?.restored?.values.child).toBeNull();
        expect(fixture.requests.some(request => request.method === "chats.get" && request.params.sessionId === "child-created")).toBe(true);
      } else expect(fixture.requests.filter(request => request.method === "chats.send")).toHaveLength(1);
    } finally { await fixture.close(); }
  }
}, 15000);
