import { requireHost } from "./host-request.ts";
import { oneLine, type AgentRunResult, type ClientEntry, type ModelEntry } from "./host-snapshot.ts";
import { C, dispatch, fail, terminalText, type CliContext, type SubCommand } from "./lib.ts";

export const SUBS: Record<string, SubCommand> = {
  list: { desc: "List agent providers and models exposed by the selected Host", fn: listAgents },
  run: { desc: "Run a prompt through an agent without mutating the selected chat", fn: runAgent },
  replay: { desc: "Replay the selected chat through an agent without mutating it", fn: replayAgent },
};

export async function agent(args: string[], context: CliContext): Promise<void> {
  return dispatch("agent", "Run Host-provided LLM agents in isolation.", SUBS, args, context);
}

async function listAgents(args: string[], context: CliContext): Promise<void> {
  const options = parseOptions(args, "list");
  const clients = await fetchAgents(context, options.timeoutMs);
  if (options.json) {
    console.log(JSON.stringify(clients, null, 2));
    return;
  }
  printAgents(clients);
}

async function runAgent(args: string[], context: CliContext): Promise<void> {
  const options = parseOptions(args, "run");
  if (!options.prompt) fail("agent run requires --prompt <text>");
  const selected = await resolveAgent(context, options.clientId, options.modelId, options.timeoutMs);
  const result = await requireHost("run-agent", context, options.timeoutMs, {
    clientId: selected.client.id,
    modelId: selected.model.id,
    prompt: options.prompt,
  });
  reportRun(result as unknown as AgentRunResult, selected.client.id, selected.model.id, options.json);
}

async function replayAgent(args: string[], context: CliContext): Promise<void> {
  const options = parseOptions(args, "replay");
  const selected = await resolveAgent(context, options.clientId, options.modelId, options.timeoutMs);
  const result = await requireHost("run-agent", context, options.timeoutMs, {
    clientId: selected.client.id,
    modelId: selected.model.id,
  });
  reportRun(result as unknown as AgentRunResult, selected.client.id, selected.model.id, options.json);
}

function parseOptions(args: string[], command: "list" | "run" | "replay"): {
  timeoutMs: number;
  json: boolean;
  clientId: string;
  modelId: string;
  prompt: string;
} {
  let timeoutMs = command === "list" ? 30000 : 120000;
  let json = false;
  let clientId = "";
  let modelId = "";
  let prompt = "";
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    if (argument === "--json") json = true;
    else if (argument === "--client") clientId = requiredValue(args[++index], "--client");
    else if (argument.startsWith("--client=")) clientId = argument.slice(9);
    else if (argument === "--model") modelId = requiredValue(args[++index], "--model");
    else if (argument.startsWith("--model=")) modelId = argument.slice(8);
    else if (argument === "--prompt" && command === "run") prompt = requiredValue(args[++index], "--prompt");
    else if (argument.startsWith("--prompt=") && command === "run") prompt = argument.slice(9);
    else if (argument === "--timeout") timeoutMs = positiveNumber(args[++index], "--timeout");
    else if (argument.startsWith("--timeout=")) timeoutMs = positiveNumber(argument.slice(10), "--timeout");
    else if (argument === "-h" || argument === "--help") {
      const usage = command === "run" ? "run --prompt <text>" : command;
      console.log(`Usage: ox [--host <url>] [--chat <id>] agent ${usage} [--client <id>] [--model <id>] [--json] [--timeout <ms>]`);
      process.exit(0);
    } else fail(`unknown option: ${argument}`);
  }
  return { timeoutMs, json, clientId, modelId, prompt };
}

async function fetchAgents(context: CliContext, timeoutMs: number): Promise<ClientEntry[]> {
  const result = await requireHost("list-models", context, timeoutMs);
  return Array.isArray(result.clients) ? result.clients as ClientEntry[] : [];
}

async function resolveAgent(
  context: CliContext,
  clientId: string,
  modelId: string,
  timeoutMs: number,
): Promise<{ client: ClientEntry; model: ModelEntry }> {
  const clients = await fetchAgents(context, timeoutMs);
  if (!clients.length) fail("Host exposes no agents");
  const client = (clientId ? clients.find(candidate => candidate.id === clientId) : clients[0])
    ?? fail(`unknown provider: ${clientId}; run ox agent list`);
  const model = (modelId ? client.models.find(candidate => candidate.id === modelId) : client.models[0])
    ?? fail(`unknown model: ${modelId} for ${client.id}; run ox agent list`);
  return { client, model };
}

function printAgents(clients: ClientEntry[]): void {
  if (!clients.length) {
    console.log("(no agents)");
    return;
  }
  for (const client of clients) {
    console.log(`${terminalText(client.id, [C.sky])}  ${client.displayName}  [${client.regions.join(", ")}]`);
    for (const model of client.models) {
      console.log(`  ${model.id}  ${model.displayName} · context ${model.maxContext.toLocaleString()} · maximum ${model.maxTokens.toLocaleString()}`);
    }
  }
}

function reportRun(run: AgentRunResult, clientId: string, modelId: string, json: boolean): void {
  if (json) {
    console.log(JSON.stringify(run, null, 2));
    return;
  }
  console.log(`${terminalText("Agent", [C.sky])}  ${clientId}:${modelId}`);
  console.log(run.message ? assistantText(run.message) : "(no message)");
  const usage = run.message?.usage;
  const tokens = usage ? `${usage.input}/${usage.output} tokens` : "no usage";
  const firstToken = run.ttftMs != null ? `first token ${run.ttftMs}ms` : "first token —";
  const total = run.totalMs != null ? `total ${run.totalMs}ms` : "total —";
  console.log(`${run.message?.stopReason ?? "?"} · ${tokens} · ${firstToken} · ${total}`);
  if (run.message?.errorMessage) process.stderr.write(`${run.message.errorMessage}\n`);
}

function assistantText(message: any): string {
  const parts: string[] = [];
  for (const block of message?.content ?? []) {
    if (block?.type === "text") {
      const text = typeof block.text === "string" ? block.text : block.text?.text ?? "";
      if (text) parts.push(text);
    } else if (block?.type === "thinking") {
      const text = typeof block.thinking === "string" ? block.thinking : block.thinking?.text ?? "";
      if (text) parts.push(`[thinking] ${oneLine(text)}`);
    } else if (block?.type === "toolCall") {
      const call = block.toolCall ?? block;
      parts.push(`→ ${call.name ?? "tool"} ${oneLine(JSON.stringify(call.arguments ?? {}))}`);
    }
  }
  return parts.join("\n") || "(no content)";
}

function requiredValue(value: string | undefined, flag: string): string {
  return value || fail(`${flag} requires a value`);
}

function positiveNumber(value: string | undefined, flag: string): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) fail(`${flag} requires a positive number`);
  return parsed;
}
