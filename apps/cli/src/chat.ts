import { connectHost, requireHost } from "./host-request.ts";
import { HostRPCClient, type HostChatRow } from "./host-rpc.ts";
import {
  formatTokenCount,
  oneLine,
  summarizeBlock,
  summarizeMessage,
  usageBreakdown,
  type ChatSnapshot,
} from "./host-snapshot.ts";
import { C, fail, terminalText, type CliContext, type SubCommand } from "./lib.ts";

type ChatOptions = {
  timeoutMs: number;
  intervalMs: number;
  json: boolean;
  full: boolean;
  sections: Set<string>;
};

export const SUBS: Record<string, SubCommand> = {
  list: { desc: "List chats exposed by the selected Host (--json)", fn: listChats },
  new: { desc: "Start a chat and make it active, optionally temporary or on a chosen model", fn: newChat },
  send: { desc: "Send a message through the real chat turn and wait for its outcome", fn: sendChat },
  stop: { desc: "Stop the selected chat's running turn", fn: stopChat },
  inspect: { desc: "Inspect the selected chat's prompt, tools, messages, and blocks", fn: inspectChat },
  watch: { desc: "Watch the selected chat for changes, reconnecting between snapshots", fn: watchChat },
};


async function listChats(args: string[], context: CliContext): Promise<void> {
  const options = parseListOptions(args);
  const host = new HostRPCClient(context.host);
  let rows: HostChatRow[];
  try {
    rows = await host.listChats(options.timeoutMs);
  } catch (error) {
    return fail((error as Error).message);
  } finally {
    host.close();
  }
  if (options.json) {
    console.log(JSON.stringify(rows, null, 2));
    return;
  }
  printChats(rows);
}

type SendResult = { chatId: string; outcome: string; text?: string; error?: string };

async function newChat(args: string[], context: CliContext): Promise<void> {
  const options = parseNewOptions(args);
  if (Boolean(options.provider) !== Boolean(options.model)) fail("chat new requires --provider and --model together");
  const result = await requireHost("chats.new", context, options.timeoutMs, {
    ...(options.temporary ? { temporary: true } : {}),
    ...(options.provider ? { providerId: options.provider, modelId: options.model } : {}),
  });
  if (options.attach.length) await requireHost("debug.chats.attachServices", context, options.timeoutMs, { domains: options.attach });
  if (options.json) console.log(JSON.stringify({ ...result, attached: options.attach }, null, 2));
  else console.log(result.chatId);
}

async function sendChat(args: string[], context: CliContext): Promise<void> {
  const options = parseSendOptions(args);
  const text = options.text === "-" ? (await Bun.stdin.text()).trim() : options.text;
  if (!text) fail("chat send requires message text");
  const result = await requireHost("chats.send", context, options.timeoutMs, { text, wait: options.wait }) as SendResult;
  if (options.json) console.log(JSON.stringify(result, null, 2));
  else if (result.outcome === "completed") console.log(result.text ?? "");
  else if (result.outcome === "queued") console.log(result.chatId);
  if (result.outcome === "completed" || result.outcome === "queued") return;
  const detail = result.outcome === "needsAttention"
    ? "chat is waiting for a user response in Ox; answer it in the app or run ox chat stop"
    : result.error ?? result.outcome;
  process.stderr.write(`chat send ${result.outcome}: ${detail} (chat ${result.chatId})\n`);
  process.exitCode = 1;
}

async function stopChat(args: string[], context: CliContext): Promise<void> {
  const options = parseListOptions(args, "stop");
  const result = await requireHost("chats.stop", context, options.timeoutMs);
  if (options.json) console.log(JSON.stringify(result, null, 2));
  else console.log(result.wasRunning ? `stop requested ${result.chatId}` : `idle ${result.chatId}`);
}

async function inspectChat(args: string[], context: CliContext): Promise<void> {
  const options = parseChatOptions(args, false);
  const snapshot = await fetchSnapshot(context, options.timeoutMs);
  printSnapshotResult(snapshot, options);
}

async function watchChat(args: string[], context: CliContext): Promise<void> {
  const options = parseChatOptions(args, true);
  let previous = "";
  let stopping = false;
  const host = connectHost(context);
  const stop = () => {
    stopping = true;
    host.close();
  };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
  try {
    while (!stopping) {
      try {
        const result = await host.request("chats.get", options.timeoutMs);
        if (stopping) break;
        const snapshot = (result.data ?? null) as ChatSnapshot | null;
        const projected = projectSnapshot(snapshot, options.sections);
        const signature = JSON.stringify(sorted(projected));
        if (signature !== previous) {
          previous = signature;
          if (options.json) console.log(JSON.stringify({ observedAt: new Date().toISOString(), data: projected }));
          else printSnapshotResult(snapshot, options);
        }
      } catch (error) {
        if (!stopping) process.stderr.write(`chat watch: ${(error as Error).message}; retrying\n`);
      }
      if (!stopping) await Bun.sleep(options.intervalMs);
    }
  } finally {
    host.close();
    process.off("SIGINT", stop);
    process.off("SIGTERM", stop);
  }
}

async function fetchSnapshot(context: CliContext, timeoutMs: number): Promise<ChatSnapshot | null> {
  const result = await requireHost("chats.get", context, timeoutMs);
  return (result.data ?? null) as ChatSnapshot | null;
}

function parseListOptions(args: string[], command: "list" | "stop" = "list"): { timeoutMs: number; json: boolean } {
  let timeoutMs = 30000;
  let json = false;
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    if (argument === "--json") json = true;
    else if (argument === "--timeout") timeoutMs = positiveNumber(args[++index], "--timeout");
    else if (argument.startsWith("--timeout=")) timeoutMs = positiveNumber(argument.slice(10), "--timeout");
    else if (argument === "-h" || argument === "--help") {
      const chat = command === "stop" ? " [--chat <id>]" : "";
      console.log(`Usage: ox [--host <url>]${chat} chat ${command} [--json] [--timeout 30000]`);
      process.exit(0);
    } else fail(`unknown option: ${argument}`);
  }
  return { timeoutMs, json };
}

function parseNewOptions(args: string[]): { timeoutMs: number; json: boolean; temporary: boolean; provider: string; model: string; attach: string[] } {
  let timeoutMs = 30000;
  let json = false;
  let temporary = false;
  let provider = "";
  let model = "";
  const attach: string[] = [];
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    if (argument === "--json") json = true;
    else if (argument === "--temporary") temporary = true;
    else if (argument === "--provider") provider = requiredValue(args[++index], "--provider");
    else if (argument.startsWith("--provider=")) provider = argument.slice(11);
    else if (argument === "--model") model = requiredValue(args[++index], "--model");
    else if (argument.startsWith("--model=")) model = argument.slice(8);
    else if (argument === "--attach") attach.push(...requiredValue(args[++index], "--attach").split(","));
    else if (argument.startsWith("--attach=")) attach.push(...argument.slice(9).split(","));
    else if (argument === "--timeout") timeoutMs = positiveNumber(args[++index], "--timeout");
    else if (argument.startsWith("--timeout=")) timeoutMs = positiveNumber(argument.slice(10), "--timeout");
    else if (argument === "-h" || argument === "--help") {
      console.log("Usage: ox [--host <url>] chat new [--temporary] [--provider <id> --model <id>] [--attach <domain,...>] [--json] [--timeout 30000]");
      console.log("       Prints the new chat id; use ox host providers for provider and model ids.");
      process.exit(0);
    } else fail(`unknown option: ${argument}`);
  }
  return { timeoutMs, json, temporary, provider, model, attach: attach.filter(Boolean) };
}

function parseSendOptions(args: string[]): { timeoutMs: number; json: boolean; wait: boolean; text: string } {
  let timeoutMs = 600000;
  let json = false;
  let wait = true;
  const words: string[] = [];
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    if (argument === "--json") json = true;
    else if (argument === "--no-wait") wait = false;
    else if (argument === "--timeout") timeoutMs = positiveNumber(args[++index], "--timeout");
    else if (argument.startsWith("--timeout=")) timeoutMs = positiveNumber(argument.slice(10), "--timeout");
    else if (argument === "-h" || argument === "--help") {
      console.log("Usage: ox [--host <url>] [--chat <id>] chat send <text | -> [--no-wait] [--json] [--timeout 600000]");
      console.log("       Runs a real chat turn with tools and services; - reads the message from stdin.");
      console.log("       Exits 1 when the turn fails, is cancelled, or needs a user response in Ox.");
      process.exit(0);
    } else if (argument.startsWith("--")) fail(`unknown option: ${argument}`);
    else words.push(argument);
  }
  return { timeoutMs, json, wait, text: words.join(" ") };
}

function requiredValue(value: string | undefined, flag: string): string {
  return value || fail(`${flag} requires a value`);
}

function parseChatOptions(args: string[], watching: boolean): ChatOptions {
  let timeoutMs = 30000;
  let intervalMs = 1000;
  let json = false;
  let full = false;
  const sections = new Set<string>();
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    if (argument === "--json") json = true;
    else if (argument === "--full") full = true;
    else if (["--system", "--tools", "--messages", "--blocks"].includes(argument)) sections.add(argument.slice(2));
    else if (argument === "--timeout") timeoutMs = positiveNumber(args[++index], "--timeout");
    else if (argument.startsWith("--timeout=")) timeoutMs = positiveNumber(argument.slice(10), "--timeout");
    else if (argument === "--interval" && watching) intervalMs = positiveNumber(args[++index], "--interval");
    else if (argument.startsWith("--interval=") && watching) intervalMs = positiveNumber(argument.slice(11), "--interval");
    else if (argument === "-h" || argument === "--help") {
      const command = watching ? "watch" : "inspect";
      const interval = watching ? " [--interval 1000]" : "";
      console.log(`Usage: ox [--host <url>] [--chat <id>] chat ${command} [--system|--tools|--messages|--blocks] [--full] [--json] [--timeout 30000]${interval}`);
      process.exit(0);
    } else fail(`unknown option: ${argument}`);
  }
  return { timeoutMs, intervalMs, json, full, sections };
}

function positiveNumber(value: string | undefined, flag: string): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) fail(`${flag} requires a positive number`);
  return parsed;
}

function printSnapshotResult(snapshot: ChatSnapshot | null, options: ChatOptions): void {
  if (options.json) {
    console.log(JSON.stringify(projectSnapshot(snapshot, options.sections), null, 2));
    return;
  }
  if (!snapshot) {
    console.log("(no active chat)");
    return;
  }
  printSnapshot(snapshot, options);
}

function projectSnapshot(snapshot: ChatSnapshot | null, sections: Set<string>): unknown {
  if (!snapshot || !sections.size) return snapshot;
  return {
    id: snapshot.id,
    model: snapshot.model,
    ...(sections.has("system") ? {
      systemPrompt: snapshot.systemPrompt,
      renderedSystemPrompt: snapshot.renderedSystemPrompt,
      soul: snapshot.soul,
      memory: snapshot.memory,
    } : {}),
    ...(sections.has("tools") ? { tools: snapshot.tools } : {}),
    ...(sections.has("messages") ? { messages: snapshot.messages } : {}),
    ...(sections.has("blocks") ? { blocks: snapshot.blocks } : {}),
  };
}

function sorted(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sorted);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, child]) => [key, sorted(child)]),
    );
  }
  return value;
}

function printChats(chats: HostChatRow[]): void {
  if (!chats.length) {
    console.log("(no chats)");
    return;
  }
  for (const chat of chats) {
    const marker = chat.active ? "*" : " ";
    const activity = (chat.lastActivity ?? chat.createdAt).slice(0, 19).replace("T", " ");
    console.log(`${marker} ${chat.id}  ${oneLine(chat.title, 40).padEnd(40)}  ${chat.model} · ${activity}`);
  }
}

function printSnapshot(snapshot: ChatSnapshot, options: ChatOptions): void {
  const show = (section: string) => options.sections.size === 0 || options.sections.has(section);
  const usage = usageBreakdown(snapshot);
  const percentage = Math.round((usage.input / usage.maximumContext) * 100);
  const cache = usage.estimated ? "estimated · no usage yet" : `${formatTokenCount(usage.cached)} cached`;
  console.log(`${terminalText("Chat", [C.sky])}       ${snapshot.id}`);
  console.log(`${terminalText("Model", [C.sky])}      ${snapshot.model.id}`);
  console.log(`${terminalText("Context", [C.sky])}    system ${formatTokenCount(usage.system)} · tools ${formatTokenCount(usage.tools)} · messages ${formatTokenCount(usage.messages)} · ${formatTokenCount(usage.input)}/${formatTokenCount(usage.maximumContext)} (${percentage}%) · ${cache}`);
  if (show("system")) {
    console.log(`\n${terminalText("SYSTEM PROMPT", [C.sky])}`);
    console.log(snapshot.systemPrompt || "(empty)");
    console.log(`\n${terminalText("SOUL", [C.sky])}`);
    console.log(snapshot.soul || "(empty)");
    console.log(`\n${terminalText("MEMORY", [C.sky])}`);
    console.log(snapshot.memory || "(empty)");
    if (options.full && snapshot.renderedSystemPrompt && snapshot.renderedSystemPrompt !== snapshot.systemPrompt) {
      console.log(`\n${terminalText("RENDERED SYSTEM PROMPT", [C.sky])}`);
      console.log(snapshot.renderedSystemPrompt);
    }
  }
  if (show("tools")) {
    console.log(`\n${terminalText("TOOLS", [C.sky])} (${snapshot.tools.length})`);
    if (!snapshot.tools.length) console.log("  (none)");
    snapshot.tools.forEach((tool, index) => {
      console.log(`  ${tool.name}  ~${formatTokenCount(usage.toolTokens[index] ?? 0)}  ${oneLine(tool.description)}`);
      if (options.full) console.log(indent(JSON.stringify(tool.parameters, null, 2)));
    });
  }
  if (show("messages")) {
    console.log(`\n${terminalText("MESSAGES", [C.sky])} (${snapshot.messages.length})`);
    if (!snapshot.messages.length) console.log("  (none)");
    snapshot.messages.forEach(message => {
      const summary = summarizeMessage(message);
      console.log(`  [${summary.kind}] ${summary.summary}`);
      if (options.full) console.log(indent(JSON.stringify(message, null, 2)));
    });
  }
  if (show("blocks")) {
    console.log(`\n${terminalText("BLOCKS", [C.sky])} (${snapshot.blocks.length})`);
    if (!snapshot.blocks.length) console.log("  (none)");
    snapshot.blocks.forEach(block => {
      const summary = summarizeBlock(block);
      console.log(`  [${summary.kind}] ${summary.summary}`);
      if (options.full) console.log(indent(JSON.stringify(block, null, 2)));
    });
  }
}

function indent(value: string): string {
  return value.split("\n").map(line => `    ${line}`).join("\n");
}
