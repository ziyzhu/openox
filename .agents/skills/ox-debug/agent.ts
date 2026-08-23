import { C, fail, dispatch, type SubCommand } from "./lib.ts";
import { type Result, runOnce } from "../../../scripts/debug-ws.ts";
import { type ClientEntry, type ModelEntry, type AgentRunResult, oneLine } from "../../../dev/snapshot.ts";

export const SUBS: Record<string, SubCommand> = {
  "list": {
    desc: "List available agents (providers + models) registered in the running app",
    fn: listAgents,
  },
  "run": {
    desc: "Send a prompt to an agent; pass [<chat>] to seed its system prompt, history, and tools",
    fn: runAgent,
  },
  "replay": {
    desc: "Replay a chat's messages 1:1 through an agent, no new prompt",
    fn: replayAgent,
  },
};

export async function agent(args: string[]): Promise<void> {
  return dispatch("agent", "Run LLM agents (provider+model) in isolation over the iOS debug WS.", SUBS, args);
}

async function listAgents(args: string[]): Promise<void> {
  let timeoutMs = 30000;
  let asJson = false;
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--timeout") { timeoutMs = Number(args[++i]) || 30000; }
    else if (a === "--json") { asJson = true; }
    else if (a === "-h" || a === "--help") {
      console.log(`Usage: debug agent list [--json] [--timeout 30000]`);
      return;
    }
  }
  const clients = await fetchAgents(timeoutMs);
  if (asJson) { console.log(JSON.stringify(clients, null, 2)); return; }
  printAgents(clients);
}

async function runAgent(args: string[]): Promise<void> {
  let timeoutMs = 120000;
  let asJson = false;
  let clientId = "";
  let modelId = "";
  let prompt = "";
  let chat = "";
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--timeout") { timeoutMs = Number(args[++i]) || 120000; }
    else if (a === "--json") { asJson = true; }
    else if (a === "--client") { clientId = args[++i] ?? ""; }
    else if (a === "--model") { modelId = args[++i] ?? ""; }
    else if (a === "--prompt") { prompt = args[++i] ?? ""; }
    else if (a === "-h" || a === "--help") {
      console.log(`Usage: debug agent run [<chat>] --prompt "..." [--client <id>] [--model <id>] [--json] [--timeout 120000]`);
      console.log(`       ${C.dim}Sends a prompt to a provider+model. Bare = fresh turn; pass a <chat> id prefix to seed that session's${C.reset}`);
      console.log(`       ${C.dim}system prompt + history + tools, then append your prompt. Read-only — the session is never mutated.${C.reset}`);
      return;
    }
    else if (!a.startsWith("-") && !chat) { chat = a; }
  }
  if (!prompt) fail(`run needs a prompt (--prompt "..."); use 'debug agent replay <chat>' to replay without one`);

  const { client, model } = await resolveAgent(clientId, modelId, timeoutMs);
  const id = crypto.randomUUID();
  const result = await runOnce(
    { kind: "run-agent", id, sessionId: chat, clientId: client.id, modelId: model.id, prompt },
    timeoutMs,
  );
  reportRun(result, client.id, model.id, asJson);
}

async function replayAgent(args: string[]): Promise<void> {
  let timeoutMs = 120000;
  let asJson = false;
  let clientId = "";
  let modelId = "";
  let chat = "";
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--timeout") { timeoutMs = Number(args[++i]) || 120000; }
    else if (a === "--json") { asJson = true; }
    else if (a === "--client") { clientId = args[++i] ?? ""; }
    else if (a === "--model") { modelId = args[++i] ?? ""; }
    else if (a === "-h" || a === "--help") {
      console.log(`Usage: debug agent replay [<chat>] [--client <id>] [--model <id>] [--json] [--timeout 120000]`);
      console.log(`       ${C.dim}Replays a chat's exact system prompt + messages + tools through the chosen provider+model as a${C.reset}`);
      console.log(`       ${C.dim}single turn. Defaults to the active chat. Read-only — the session is never mutated.${C.reset}`);
      return;
    }
    else if (!a.startsWith("-") && !chat) { chat = a; }
  }

  const { client, model } = await resolveAgent(clientId, modelId, timeoutMs);
  const id = crypto.randomUUID();
  const result = await runOnce(
    { kind: "run-agent", id, sessionId: chat, clientId: client.id, modelId: model.id },
    timeoutMs,
  );
  reportRun(result, client.id, model.id, asJson);
}

async function fetchAgents(timeoutMs: number): Promise<ClientEntry[]> {
  const res = await runOnce({ kind: "list-models", id: crypto.randomUUID() }, timeoutMs);
  if (!res.ok) fail(`list-models failed: ${res.error}`);
  return ((res as Result & { clients?: unknown }).clients ?? []) as ClientEntry[];
}

async function resolveAgent(clientId: string, modelId: string, timeoutMs: number): Promise<{ client: ClientEntry; model: ModelEntry }> {
  const clients = await fetchAgents(timeoutMs);
  if (clients.length === 0) fail("no agents registered");
  const client = clientId ? clients.find(c => c.id === clientId) : clients[0];
  if (!client) return fail(`unknown provider: ${clientId} (try: debug agent list)`);
  const model = modelId ? client.models.find(m => m.id === modelId) : client.models[0];
  if (!model) return fail(`unknown model: ${modelId} for ${client.id} (try: debug agent list)`);
  return { client, model };
}

function reportRun(result: Result, clientId: string, modelId: string, asJson: boolean): void {
  if (asJson) { console.log(JSON.stringify(result, null, 2)); return; }
  if (!result.ok) fail(`agent failed: ${result.error}`);
  printAgentRun(result as unknown as AgentRunResult, clientId, modelId);
}

function printAgents(clients: ClientEntry[]): void {
  console.log("");
  if (clients.length === 0) { console.log(`  ${C.dim}(no agents)${C.reset}\n`); return; }
  for (const c of clients) {
    console.log(`${C.cyan}${c.id}${C.reset}  ${c.displayName}  ${C.dim}[${c.regions.join(", ")}]${C.reset}`);
    for (const m of c.models) {
      console.log(`  ${m.id}  ${C.dim}${m.displayName} · ctx ${m.maxContext.toLocaleString()} · max ${m.maxTokens.toLocaleString()}${C.reset}`);
    }
  }
  console.log("");
}

function assistantText(message: any): string {
  const blocks = message?.content ?? [];
  const parts: string[] = [];
  for (const b of blocks) {
    if (b?.type === "text") {
      const t = typeof b.text === "string" ? b.text : b.text?.text ?? "";
      if (t) parts.push(t);
    } else if (b?.type === "thinking") {
      const t = typeof b.thinking === "string" ? b.thinking : b.thinking?.text ?? "";
      if (t) parts.push(`${C.dim}[thinking] ${oneLine(t)}${C.reset}`);
    } else if (b?.type === "toolCall") {
      const tc = b.toolCall ?? b;
      parts.push(`${C.cyan}→ ${tc.name ?? "tool"}${C.reset} ${oneLine(JSON.stringify(tc.arguments ?? {}))}`);
    }
  }
  return parts.join("\n") || "(no content)";
}

function printAgentRun(run: AgentRunResult, clientId: string, modelId: string): void {
  console.log("");
  console.log(`${C.cyan}agent${C.reset} ${clientId}:${modelId}`);
  console.log(run.message ? assistantText(run.message) : "(no message)");
  const u = run.message?.usage;
  const stop = run.message?.stopReason ?? "?";
  const tokens = u ? `${u.input}/${u.output} tok` : "no usage";
  const ttft = run.ttftMs != null ? `ttft ${run.ttftMs}ms` : "ttft —";
  const total = run.totalMs != null ? `total ${run.totalMs}ms` : "total —";
  console.log(`${C.dim}${stop} · ${tokens} · ${ttft} · ${total}${C.reset}`);
  if (run.message?.errorMessage) console.log(`${C.red}${run.message.errorMessage}${C.reset}`);
  console.log("");
}
