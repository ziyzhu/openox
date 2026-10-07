import { expect, test } from "bun:test";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ROOT } from "../../../../lib.ts";
import { validateParams, validateResult } from "../../../../../packages/protocol/src/index.ts";
import type { EvalBlock, EvalMessage, Report } from "../../../evals/scripts/types.ts";

type Scenario = "pass" | "wrong" | "attention" | "timeout" | "provider-error" | "busy" | "fake-guidance" | "tool-error"
  | "forged-guidance" | "alias-guidance" | "mutated-state" | "missing-observation" | "skill-claim" | "skill-corrupt"
  | "skill-probe-fail" | "cleanup-error" | "cleanup-policy" | "probe-mutation" | "truncated-receipts" | "missing-settings" | "skill-extra-action";
type Chat = { messages: EvalMessage[]; blocks: EvalBlock[]; isBusy: boolean; temporary: boolean; pendingPrompt?: { id: string; prompt: string; options: string[]; allowsCustomAnswer: boolean; requiresApp: boolean } };
const guide = "# Workflow guide\n\nRead the task, inspect existing state, propose the work, and verify its result before reporting completion.\n";
const skillInstructions = (answer: string) => `Reply with exactly ${answer} and nothing else. Do not use external services or modify files.`;
const skillFile = (name: string, answer: string) => `---\nname: ${name}\ndescription: Return a QA verification token.\n---\n\n${skillInstructions(answer)}\n`;

async function exercise(scenario: Scenario = "pass") {
  const directory = await mkdtemp(join(tmpdir(), "ox-eval-cli-e2e-"));
  const requests: Array<{ method: string; params: Record<string, unknown> }> = [];
  const model = { id: "example", providerModelID: "example", displayName: "Example", maxTokens: 1000, maxContext: 10000,
    supportsTools: true, reasoning: false, reasoningEfforts: [], inputModalities: ["text"], outputModalities: ["text"] };
  const providers = [{ id: "example", displayName: "Example", regions: ["global"], supportsTools: true,
    reasoningPolicy: "none", credentialID: "example", models: [model] }];
  const files: Record<string, string> = { "MEMORY.md": "Preserve my memory.", "SOUL.md": "Preserve my preferences.", "skills/existing/SKILL.md": skillFile("existing", "EXISTING") };
  const chats = new Map<string, Chat>();
  let active = "";
  let language = "en";
  const snapshot = (id: string) => ({ id, model, systemPrompt: scenario === "wrong" ? "Candidate prompt" : "E2E fixture", renderedSystemPrompt: "E2E fixture",
    soul: "", memory: "", tools: [{ name: "execute", description: "E2E tool", parameters: {}, strict: true }], ...chats.get(id) });
  function executed(chat: Chat, source: string, name: string, args: Record<string, unknown>, text: string, failed = false) {
    const id = `tool-${chat.messages.length}`;
    chat.messages.push({ type: "assistant", assistant: { content: [{ type: "toolCall", toolCall: { id, name: "execute", arguments: { source } } }], stopReason: "toolUse" } },
      { type: "toolResult", toolResult: { toolCallId: id, toolName: "execute", content: [{ type: "text", text: { text } }], isError: failed } });
    if (scenario !== "fake-guidance") chat.blocks.push({ kind: { type: "thinking", trace: { entries: [{ invocation: { name, args, outcome: failed ? { failed: { _0: text } } : { succeeded: { _0: text } } } }],
      omittedInvocations: scenario === "truncated-receipts" ? 1 : 0 } } });
  }
  const server = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    fetch(request, server) {
      if (server.upgrade(request)) return;
      return new Response("WebSocket required", { status: 400 });
    },
    websocket: {
      message(socket, message) {
        const request = JSON.parse(String(message));
        requests.push(request);
        const reply = { jsonrpc: "2.0", id: request.id };
        const reject = (message: string): void => { socket.send(JSON.stringify({ ...reply, error: { code: -32000, message } })); };
        if (!validateParams(request.method, request.params ?? {})) return reject("Invalid params");
        const id = request.params.sessionId ?? active;
        const chat = chats.get(id);
        let result: unknown;
        switch (request.method) {
          case "host.describe": result = { implementation: { name: "Eval E2E Host", version: "1", build: "1" }, protocols: { host: [1] },
            methods: ["chats.new", "chats.send", "chats.get", "chats.stop", "chats.open", "logs.list", "providers.list", "vm.call"] }; break;
          case "providers.list": result = { region: "global", providers }; break;
          case "chats.new":
            active = `eval-${chats.size + 1}`;
            chats.set(active, { messages: [], blocks: [], isBusy: false, temporary: request.params.temporary === true });
            result = { chatId: active, temporary: request.params.temporary === true, model: "example:example" };
            break;
          case "chats.open":
            if (!chat || chat.temporary) return reject("Saved chat not found");
            active = id;
            result = { data: snapshot(id) };
            break;
          case "chats.get": result = chat ? { data: snapshot(id) } : scenario === "busy"
            ? { data: { ...snapshot("other-agent"), messages: [], blocks: [], isBusy: true } } : {}; break;
          case "chats.send": {
            if (!chat) return reject("Unknown chat");
            chat.isBusy = scenario === "timeout" || scenario === "attention";
            if (scenario === "timeout") return;
            if (scenario === "provider-error") return reject("Provider unavailable");
            if (scenario === "attention") {
              chat.pendingPrompt = { id: "approval", prompt: "Approve?", options: ["Approve", "Deny"], allowsCustomAnswer: false, requiresApp: false };
              result = { chatId: id, outcome: "needsAttention" };
              break;
            }
            const prompt = String(request.params.text);
            let answer = prompt.includes("17 plus 25") ? "42" : prompt.includes("Correction:") ? "Tokyo"
              : prompt.includes("Paris") ? "OK" : prompt.includes("maple") ? "13" : "ready";
            if (prompt.includes("built-in workflow guide")) {
              const path = prompt.includes("subscription") ? "visualize" : prompt.includes("provider") ? "manage-providers"
                : prompt.includes("reusable Profile") ? "manage-skills" : prompt.includes("durable personal") ? "import-memory" : "evolve";
              const source = scenario === "fake-guidance" ? `console.log("ox.fs.read guidance/${path}/guide.md")`
                : scenario === "alias-guidance" ? `const read = ox.fs.read; console.log(await read({ path: "guidance/${path}/guide.md" }));`
                : `console.log(await ox.fs.read({ path: "guidance/${path}/guide.md" }));`;
              executed(chat, source, "ox.fs.read", { path: `guidance/${path}/guide.md` }, scenario === "tool-error" ? "Read failed" : scenario === "forged-guidance" ? "Invented guide" : guide, scenario === "tool-error");
              if (scenario === "mutated-state") files["MEMORY.md"] = "Changed without permission.";
              answer = "Read the guide, then review the plan before proceeding.";
            }
            if (prompt.startsWith("Create a Profile-owned skill named ")) {
              const name = prompt.match(/named ([a-z0-9-]+)/)![1]!;
              const token = prompt.match(/OX_EVAL_OK_[a-f0-9]+/)![0];
              if (scenario !== "skill-claim") {
                files[`skills/${name}/SKILL.md`] = skillFile(name, scenario === "skill-corrupt" ? "WRONG" : token);
                executed(chat, "console.log(await ox.skill.create({ name: 'fixture' }));", "ox.skill.create", { name }, "Created skill");
                if (scenario === "skill-extra-action") executed(chat, "console.log(await ox.service.add({}));", "ox.service.add", {}, "Added an unrelated service");
              }
              answer = "Created the requested skill.";
            }
            if (prompt.startsWith("Read and use the Profile skill ")) {
              const name = prompt.match(/skill ([a-z0-9-]+)/)![1]!;
              const path = `skills/${name}/SKILL.md`;
              const text = files[path]!;
              executed(chat, `console.log(await ox.fs.read({ path: '${path}' }));`, "ox.fs.read", { path }, text);
              answer = scenario === "skill-probe-fail" ? "WRONG" : text.match(/Reply with exactly (\S+)/)![1]!;
              if (scenario === "probe-mutation") language = "zh-Hans";
            }
            if (scenario === "wrong") answer = "wrong";
            chat.messages.push({ type: "assistant", assistant: { content: [{ type: "text", text: { text: answer } }], stopReason: "stop" } });
            result = { chatId: id, outcome: "completed", text: answer };
            break;
          }
          case "chats.stop":
            if (!chat) return reject("Unknown chat");
            result = { chatId: id, wasRunning: chat.isBusy };
            chat.isBusy = false;
            delete chat.pendingPrompt;
            break;
          case "vm.call": {
            if (!chat) return reject("Unknown observer chat");
            const args = request.params.arguments;
            let value: unknown;
            if (scenario === "missing-observation") { result = {}; break; }
            switch (request.params.function) {
              case "ox.app.profile": value = { name: "EvalQA", storage: "local" }; break;
              case "ox.app.defaultModel": value = { configured: false, region: "global", provider: { id: "example", name: "Example" }, model: { id: "example", name: "Example" }, thinkingLevel: null, supportsTools: true, authentication: { method: "apiKey", status: "ready", settingsPath: "Settings" } }; break;
              case "ox.app.language": value = { selection: language, locale: language }; break;
              case "ox.app.theme": value = scenario === "missing-settings" ? {} : { selection: "light", appearance: "light" }; break;
              case "ox.app.actionPolicies": value = { defaultPolicy: null, overrides: [], truncated: false, resolved: args.action
                ? { action: args.action, policy: scenario === "cleanup-policy" && args.action === "ox.skill.delete" ? "ask" : "allow" } : null }; break;
              case "ox.fs.list": value = { items: [], truncated: false }; break;
              case "ox.fs.glob": value = { paths: Object.keys(files).filter(path => path.startsWith("skills/")).sort(), truncated: false }; break;
              case "ox.fs.read": value = { path: args.path, text: args.path.startsWith("guidance/") ? guide : files[args.path], truncated: false, unsupported: null }; break;
              case "ox.skill.delete":
                if (scenario === "cleanup-error") return reject("Cleanup unavailable");
                if (chat.temporary) return reject("Temporary chats cannot delete Profile skills");
                if (!args.name.startsWith("ox-eval-")) return reject("Not a run-owned skill");
                for (const path of Object.keys(files)) if (path.startsWith(`skills/${args.name}/`)) delete files[path];
                value = { name: args.name, deleted: true };
                break;
              default: return reject(`Unexpected observation ${request.params.function}`);
            }
            result = { value };
            break;
          }
          case "logs.list": result = request.params.cursor ? { logs: [{ seq: 1, time: new Date().toISOString(), level: "error", category: "Other",
            thread: "", location: "fixture", message: "Unrelated Host activity" }], hasMore: false }
            : { logs: [{ seq: 2, time: new Date().toISOString(), level: "info", category: "Agent", thread: "", location: "fixture",
              message: `chat=${active} outcome=completed` }], hasMore: true, nextCursor: "older" }; break;
          default: throw new Error(`Unexpected method ${request.method}`);
        }
        if (!validateResult(request.method, result)) throw new Error(`Invalid fixture result: ${request.method}`);
        socket.send(JSON.stringify({ ...reply, result }));
      },
    },
  });
  async function run(...args: string[]) {
    const output = join(directory, `report-${Date.now()}.json`);
    const child = Bun.spawn([process.execPath, "--no-env-file", `${ROOT}/.agents/skills/evals/scripts/runner.ts`,
      "--host", `ws://127.0.0.1:${server.port}`, "--provider", "example", "--model", "example", "--output", output, ...args], {
      cwd: ROOT, stdout: "pipe", stderr: "pipe", stdin: "ignore",
    });
    const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
    return { code, stdout, stderr, report: await Bun.file(output).exists() ? JSON.parse(await readFile(output, "utf8")) as Report : undefined, output };
  }
  return { run, requests, files, close: async () => { server.stop(true); await rm(directory, { recursive: true, force: true }); } };
}

const workflowArgs = ["--case", "create-skill", "--allow-profile-writes", "--qa-profile", "EvalQA"];

test("eval runner uses real CLI chat commands, isolates repetitions, and preserves paginated diagnostics", async () => {
  const fixture = await exercise();
  try {
    const result = await fixture.run("--suite", "quick", "--repeat", "2");
    expect(result.code).toBe(0);
    expect(result.report?.mode).toBe("ox-cli-chat");
    expect(result.report?.results).toHaveLength(8);
    expect(new Set(result.report?.results.map(attempt => attempt.response?.chatId)).size).toBe(8);
    expect(result.report?.results.every(attempt => attempt.status === "pass")).toBe(true);
    const correction = result.report!.results.find(attempt => attempt.id === "latest-instruction")!;
    expect(correction.response?.outcomes).toHaveLength(2);
    expect(correction.response?.logs).toHaveLength(2);
    expect((await stat(result.output)).mode & 0o777).toBe(0o600);
    expect(fixture.requests.every(request => request.method !== "agents.evaluate")).toBe(true);
  } finally { await fixture.close(); }
}, 30000);

test("guidance grading uses independent contents and actual receipts, including aliased calls", async () => {
  for (const scenario of ["pass", "alias-guidance", "fake-guidance", "tool-error", "forged-guidance"] as const) {
    const fixture = await exercise(scenario);
    try {
      const result = await fixture.run("--case", "guidance-canvas");
      const passes = scenario === "pass" || scenario === "alias-guidance";
      expect(result.code).toBe(passes ? 0 : 1);
      const attempt = result.report!.results[0]!;
      expect(attempt.status).toBe(passes ? "pass" : "fail");
      expect(attempt.response?.before?.guide).toBe(guide);
      expect(attempt.response?.after?.guide).toBe(guide);
      expect(attempt.response?.before?.chatId).not.toBe(attempt.response?.chatId);
      expect(attempt.response?.after?.chatId).not.toBe(attempt.response?.before?.chatId);
    } finally { await fixture.close(); }
  }
}, 20000);

test("state mutation stops the cohort without repair, and missing observations are errors", async () => {
  for (const scenario of ["mutated-state", "missing-observation", "missing-settings", "truncated-receipts"] as const) {
    const fixture = await exercise(scenario);
    try {
      const result = await fixture.run("--case", "guidance-canvas", "--repeat", "2");
      expect(result.code).toBe(1);
      expect(result.report?.results).toHaveLength(1);
      expect(result.report?.results[0]?.status).toBe(scenario === "mutated-state" ? "fail" : "error");
      expect(fixture.requests.some(request => request.params.function === "ox.fs.write")).toBe(false);
      if (scenario === "mutated-state") expect(fixture.files["MEMORY.md"]).toBe("Changed without permission.");
    } finally { await fixture.close(); }
  }
}, 15000);

test("skill workflow verifies persisted state, fresh-chat behavior, and only owned cleanup", async () => {
  const fixture = await exercise();
  try {
    const result = await fixture.run(...workflowArgs);
    expect(result.code).toBe(0);
    const response = result.report!.results[0]!.response!;
    expect(response.probe?.status).toBe("ran");
    expect(response.fixture?.name).toMatch(/^ox-eval-/);
    expect(response.after?.files[`skills/${response.fixture!.name}/SKILL.md`]).toContain(response.fixture!.answer);
    expect(response.restored?.files).toEqual(response.before?.files);
    if (response.probe?.status === "ran") {
      expect(response.probe.evidence.chatId).not.toBe(response.chatId);
      expect(response.probe.evidence.initial?.messages).toEqual([]);
    }
    expect(fixture.requests.filter(request => request.method === "chats.new" && request.params.temporary !== true)).toHaveLength(1);
    expect(fixture.requests.filter(request => request.params.function === "ox.skill.delete")).toHaveLength(1);
    expect(fixture.files["skills/existing/SKILL.md"]).toBe(skillFile("existing", "EXISTING"));
    expect(Object.keys(fixture.files).some(path => path.includes("ox-eval-"))).toBe(false);
  } finally { await fixture.close(); }
}, 15000);

test("skill claims, incorrect files, and failed behavior cannot pass; cleanup cannot hide collateral changes", async () => {
  for (const scenario of ["skill-claim", "skill-corrupt", "skill-probe-fail", "probe-mutation", "skill-extra-action", "cleanup-error"] as const) {
    const fixture = await exercise(scenario);
    try {
      const result = await fixture.run(...workflowArgs);
      expect(result.code).toBe(1);
      expect(result.report?.results[0]?.status).toBe(scenario === "cleanup-error" ? "error" : "fail");
      if (scenario !== "cleanup-error") expect(Object.keys(fixture.files).some(path => path.includes("ox-eval-"))).toBe(false);
      if (["skill-claim", "skill-extra-action"].includes(scenario)) expect(result.report?.results[0]?.response?.probe?.status).toBe("skipped");
      if (scenario === "skill-extra-action") expect(result.report?.results[0]?.response?.continuation).toBe("stop");
      expect(fixture.requests.some(request => request.method === "chats.respond")).toBe(false);
    } finally { await fixture.close(); }
  }
}, 30000);

test("workflows require opt-in, the named QA Profile, and existing cleanup permission before mutation", async () => {
  for (const args of [["--case", "create-skill"], [...workflowArgs.slice(0, 3)], [...workflowArgs.slice(0, 3), "--qa-profile", "WrongQA"]]) {
    const fixture = await exercise();
    try {
      const result = await fixture.run(...args);
      expect(result.code).toBe(1);
      expect(fixture.requests.some(request => request.method === "chats.send" || request.method === "chats.new" && request.params.temporary !== true)).toBe(false);
    } finally { await fixture.close(); }
  }
  const fixture = await exercise("cleanup-policy");
  try {
    const result = await fixture.run(...workflowArgs);
    expect(result.code).toBe(1);
    expect(fixture.requests.some(request => request.method === "chats.send")).toBe(false);
    expect(Object.keys(fixture.files).some(path => path.includes("ox-eval-"))).toBe(false);
  } finally { await fixture.close(); }
});

test("eval runner never approves pending prompts or retries errored submissions", async () => {
  for (const scenario of ["attention", "provider-error", "timeout"] as const) {
    const fixture = await exercise(scenario);
    try {
      const result = await fixture.run("--case", "brief-answer", "--timeout", "1000");
      expect(result.code).toBe(1);
      const response = result.report?.results[0]?.response;
      expect(result.report?.results[0]?.status).toBe(scenario === "attention" ? "fail" : "error");
      expect(fixture.requests.filter(request => request.method === "chats.send")).toHaveLength(1);
      expect(fixture.requests.filter(request => request.method === "chats.stop")).toHaveLength(1);
      expect(fixture.requests.some(request => request.method === "chats.respond")).toBe(false);
      expect(response?.snapshot?.isBusy).toBe(false);
      if (scenario === "attention") expect(response?.attention?.pendingPrompt?.id).toBe("approval");
      expect(response?.logs).toHaveLength(2);
    } finally { await fixture.close(); }
  }
}, 15000);

test("eval runner leaves an already busy chat untouched", async () => {
  const fixture = await exercise("busy");
  try {
    const result = await fixture.run("--case", "brief-answer");
    expect(result.code).toBe(1);
    expect(result.stderr).toContain("leave it untouched");
    expect(fixture.requests.some(request => ["chats.new", "chats.send", "chats.stop"].includes(request.method))).toBe(false);
  } finally { await fixture.close(); }
});

test("eval comparison detects regressions across prompt changes and rejects changed models and missing attempts", async () => {
  const fixtures = [await exercise(), await exercise("wrong")];
  try {
    const baseline = await fixtures[0]!.run("--case", "brief-answer");
    const candidate = await fixtures[1]!.run("--case", "brief-answer");
    async function compare() {
      const child = Bun.spawn([process.execPath, `${ROOT}/.agents/skills/evals/scripts/runner.ts`, "compare", baseline.output, candidate.output], { stdout: "pipe", stderr: "pipe" });
      const [code, stdout] = await Promise.all([child.exited, new Response(child.stdout).text()]);
      return { code, changes: JSON.parse(stdout) };
    }
    expect((await compare()).changes[0]).toMatchObject({ change: "regression", contextChanged: true });
    candidate.report!.model = "different";
    await writeFile(candidate.output, JSON.stringify(candidate.report));
    expect((await compare()).changes[0]).toMatchObject({ change: "not-comparable", modelChanged: true });
    candidate.report!.model = baseline.report!.model;
    candidate.report!.results[0]!.repetition = 2;
    await writeFile(candidate.output, JSON.stringify(candidate.report));
    expect((await compare()).code).toBe(2);
    baseline.report!.limits.repetitions = candidate.report!.limits.repetitions = 2;
    candidate.report!.results[0]!.repetition = 1;
    await writeFile(baseline.output, JSON.stringify(baseline.report));
    await writeFile(candidate.output, JSON.stringify(candidate.report));
    expect((await compare()).code).toBe(2);
    candidate.report!.results = [];
    await writeFile(candidate.output, JSON.stringify(candidate.report));
    expect((await compare()).changes[0]).toMatchObject({ change: "not-comparable", attempts: [1, 0] });
    baseline.report!.plannedCases.push("never-executed");
    candidate.report!.plannedCases.push("never-executed");
    await writeFile(baseline.output, JSON.stringify(baseline.report));
    await writeFile(candidate.output, JSON.stringify(candidate.report));
    expect((await compare()).changes[1]).toMatchObject({ id: "never-executed", change: "not-comparable", attempts: [0, 0] });
  } finally { await Promise.all(fixtures.map(fixture => fixture.close())); }
});
