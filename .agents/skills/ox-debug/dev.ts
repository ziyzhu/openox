import { C, dispatch, fail, failResult, printResult, type SubCommand } from "./lib.ts";
import { runOnce } from "../../../scripts/debug-ws.ts";
import {
  type Snapshot,
  oneLine,
  fmtK,
  summarizeMessage,
  summarizeBlock,
  usageBreakdown,
} from "../../../dev/snapshot.ts";

export const SUBS: Record<string, SubCommand> = {
  "chat": {
    desc: "Print a chat's system prompt, tools, messages, and blocks; defaults to the active chat (--json, --full)",
    fn: chat,
  },
  "list-chats": {
    desc: "List the iOS app's chat sessions and their ids (--json)",
    fn: listChats,
  },
  "logs": {
    desc: "Print the iOS app's in-memory logs (--level, --grep, --json)",
    fn: logs,
  },
  "transcript": {
    desc: "Print the active transcript scroller state and recent geometry history (--json)",
    fn: transcript,
  },
  "performance": {
    desc: "Benchmark projection and service search and print the latest render counters (--json)",
    fn: performance,
  },
  "virtual-machine-eval": {
    desc: "Run a JS snippet in a chat's agent virtual machine (the `ox` namespace) in the running iOS simulator",
    fn: virtualMachineEval,
  },
};

export async function dev(args: string[]): Promise<void> {
  return dispatch("dev", "Live introspection of the running iOS app: chats, logs, and the agent virtual machine.", SUBS, args);
}

async function virtualMachineEval(args: string[]): Promise<void> {
  let script = "";
  let sessionId = "";
  let timeoutMs = 60000;
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--script") { script = args[++i] ?? ""; }
    else if (a === "--chat") { sessionId = args[++i] ?? ""; }
    else if (a === "--timeout") { timeoutMs = Number(args[++i]) || 60000; }
    else if (a === "-h" || a === "--help") {
      console.log(`Usage: debug dev virtual-machine-eval [--chat <id>] [--script 'console.log(await ox.app.inspect({ purpose: "Inspect app" }))'] [--timeout 60000]`);
      console.log(`       ${C.dim}Runs in the chat's agent JSContext where the ox namespace is bound. Defaults to the active chat.${C.reset}`);
      console.log(`       ${C.dim}script may also be passed as a positional arg.${C.reset}`);
      return;
    }
    else if (!script) { script = a; }
  }
  if (!script) fail("expected a script (via --script or a positional arg)");

  const id = crypto.randomUUID();
  printResult(await runOnce({ kind: "virtual-machine-eval", id, sessionId, script }, timeoutMs), "virtual-machine-eval");
}

async function transcript(args: string[]): Promise<void> {
  let timeoutMs = 30000;
  let asJson = false;
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--timeout") { timeoutMs = Number(args[++i]) || 30000; }
    else if (a === "--json") { asJson = true; }
    else if (a === "-h" || a === "--help") {
      console.log("Usage: debug dev transcript [--json] [--timeout 30000]");
      return;
    }
  }

  const id = crypto.randomUUID();
  const result = await runOnce({ kind: "get-transcript", id }, timeoutMs);
  if (!result.ok) failResult("transcript", result.error);
  const transcript = result.transcript as TranscriptSnapshot | undefined;
  if (!transcript) return fail("transcript unavailable");
  if (asJson) { console.log(JSON.stringify(transcript, null, 2)); return; }
  printTranscript(transcript);
}

type TranscriptSnapshot = {
  chatID: string;
  frame?: string;
  position: string;
  owner: string;
  restingFromEnd: number;
  insetsSettling: boolean;
  showsJumpButton: boolean;
  history: string[];
};

function printTranscript(snapshot: TranscriptSnapshot): void {
  console.log("");
  console.log(`  chat=${snapshot.chatID} position=${snapshot.position} owner=${snapshot.owner}`);
  console.log(`  frame=${snapshot.frame ?? "none"} restingFromEnd=${snapshot.restingFromEnd} insetsSettling=${snapshot.insetsSettling} jump=${snapshot.showsJumpButton}`);
  if (snapshot.history.length) {
    console.log("");
    for (const entry of snapshot.history) console.log(`  ${entry}`);
  }
  console.log("");
}

async function chat(args: string[]): Promise<void> {
  let timeoutMs = 30000;
  let asJson = false;
  let full = false;
  let sessionId = "";
  const sections = new Set<string>();
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--timeout") { timeoutMs = Number(args[++i]) || 30000; }
    else if (a === "--json") { asJson = true; }
    else if (a === "--full") { full = true; }
    else if (a === "--system" || a === "--tools" || a === "--messages" || a === "--blocks") { sections.add(a.slice(2)); }
    else if (a === "-h" || a === "--help") {
      console.log(`Usage: debug dev chat [<id>] [--system|--tools|--messages|--blocks] [--full] [--json] [--timeout 30000]`);
      console.log(`       ${C.dim}Mirrors the dev website. Defaults to the active chat; pass an id (from debug dev list-chats) to target another.${C.reset}`);
      return;
    }
    else if (!a.startsWith("-") && !sessionId) { sessionId = a; }
  }

  const id = crypto.randomUUID();
  const result = await runOnce({ kind: "get-chat", id, sessionId }, timeoutMs);
  if (!result.ok) failResult("chat", result.error);
  const snap = result.data as Snapshot | null | undefined;
  if (!snap) {
    if (asJson) { console.log("null"); return; }
    console.log("\n(no active chat)\n");
    return;
  }
  if (asJson) { console.log(JSON.stringify(snap, null, 2)); return; }
  printSnapshot(snap, { sections, full });
}

type ChatRow = {
  id: string;
  title: string;
  model: string;
  createdAt: string;
  lastActivity: string | null;
  messages: number;
  blocks: number;
  active: boolean;
};

async function listChats(args: string[]): Promise<void> {
  let timeoutMs = 30000;
  let asJson = false;
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--timeout") { timeoutMs = Number(args[++i]) || 30000; }
    else if (a === "--json") { asJson = true; }
    else if (a === "-h" || a === "--help") {
      console.log(`Usage: debug dev list-chats [--json] [--timeout 30000]`);
      return;
    }
  }

  const id = crypto.randomUUID();
  const result = await runOnce({ kind: "list-chats", id }, timeoutMs);
  if (!result.ok) failResult("list-chats", result.error);
  const chats = (result.chats ?? []) as ChatRow[];
  if (asJson) { console.log(JSON.stringify(chats, null, 2)); return; }
  printChats(chats);
}

type LogRow = { seq: number; time: string; level: string; category: string; thread?: string; location: string; message: string };

const LOG_LEVELS = ["debug", "info", "warning", "error"];

async function logs(args: string[]): Promise<void> {
  let timeoutMs = 30000;
  let asJson = false;
  let level = "";
  let grep = "";
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--timeout") { timeoutMs = Number(args[++i]) || 30000; }
    else if (a === "--json") { asJson = true; }
    else if (a === "--level") { level = (args[++i] ?? "").toLowerCase(); }
    else if (a === "--grep") { grep = args[++i] ?? ""; }
    else if (a === "-h" || a === "--help") {
      console.log(`Usage: debug dev logs [--level ${LOG_LEVELS.join("|")}] [--grep <substr>] [--json] [--timeout 30000]`);
      console.log(`       ${C.dim}Dumps the running iOS app's in-memory log buffer (newest last). --level shows that level and above.${C.reset}`);
      return;
    }
  }

  const id = crypto.randomUUID();
  const result = await runOnce({ kind: "get-logs", id }, timeoutMs);
  if (!result.ok) failResult("logs", result.error);
  let rows = (result.logs ?? []) as LogRow[];
  const min = LOG_LEVELS.indexOf(level);
  if (min >= 0) rows = rows.filter((r) => LOG_LEVELS.indexOf(r.level) >= min);
  if (grep) {
    const needle = grep.toLowerCase();
    rows = rows.filter((r) => r.message.toLowerCase().includes(needle) || r.category.toLowerCase().includes(needle));
  }
  if (asJson) { console.log(JSON.stringify(rows, null, 2)); return; }
  printLogs(rows);
}

async function performance(args: string[]): Promise<void> {
  let timeoutMs = 30000;
  let asJson = false;
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--timeout") { timeoutMs = Number(args[++i]) || 30000; }
    else if (a === "--json") { asJson = true; }
    else if (a === "-h" || a === "--help") {
      console.log(`Usage: debug dev performance [--json] [--timeout 30000]`);
      return;
    }
  }

  const id = crypto.randomUUID();
  const result = await runOnce({ kind: "get-performance", id }, timeoutMs);
  if (!result.ok) failResult("performance", result.error);
  if (asJson) {
    console.log(JSON.stringify(result.data, null, 2));
    return;
  }
  console.log(JSON.stringify(result.data, null, 2));
}

function printLogs(rows: LogRow[]): void {
  console.log("");
  if (rows.length === 0) { console.log(`  ${C.dim}(no logs)${C.reset}\n`); return; }
  for (const r of rows) {
    const time = r.time.slice(11, 23).padEnd(12);
    const level = r.level.toUpperCase().padEnd(7);
    const thread = r.thread ? `${C.dim}(${r.thread})${C.reset} ` : "";
    console.log(`${C.dim}${time}${C.reset} ${level} ${C.cyan}${r.category}${C.reset} ${thread}${C.dim}${r.location}${C.reset} ${r.message}`);
  }
  console.log("");
}

function printChats(chats: ChatRow[]): void {
  console.log("");
  if (chats.length === 0) { console.log(`  ${C.dim}(no chats)${C.reset}\n`); return; }
  for (const c of chats) {
    const mark = c.active ? `${C.cyan}*${C.reset}` : " ";
    const idShort = c.active ? `${C.cyan}${c.id.slice(0, 8)}${C.reset}` : c.id.slice(0, 8);
    const when = (c.lastActivity ?? c.createdAt).slice(0, 19).replace("T", " ");
    const title = oneLine(c.title, 40).padEnd(40);
    console.log(`${mark} ${idShort}  ${title}  ${C.dim}${c.model} · ${c.messages} msgs · ${c.blocks} blocks · ${when}${C.reset}`);
  }
  console.log("");
}

function indent(s: string, pad = "    "): string {
  return s.split("\n").map((l) => pad + l).join("\n");
}

function printSnapshot(snap: Snapshot, opts: { sections: Set<string>; full: boolean }): void {
  const show = (s: string) => opts.sections.size === 0 || opts.sections.has(s);
  const u = usageBreakdown(snap);
  const pct = Math.round((u.input / u.maxCtx) * 100);
  const cacheNote = u.estimated ? "estimated · no usage yet" : `${fmtK(u.cached)} cached`;

  console.log("");
  console.log(`${C.cyan}chat${C.reset} ${snap.id.slice(0, 8)} · model=${snap.model.id} · ctx=${snap.model.maxContext.toLocaleString()}`);
  console.log(`${C.dim}context${C.reset} system ${fmtK(u.system)} · tools ${fmtK(u.tools)} · messages ${fmtK(u.messages)} · ${fmtK(u.input)}/${fmtK(u.maxCtx)} (${pct}%) · ${cacheNote}`);

  if (show("system")) {
    console.log(`\n${C.cyan}SYSTEM PROMPT${C.reset}`);
    console.log(snap.systemPrompt || "(empty)");
  }
  if (show("tools")) {
    console.log(`\n${C.cyan}TOOLS${C.reset} ${C.dim}(${snap.tools.length})${C.reset}`);
    if (snap.tools.length === 0) console.log(`  ${C.dim}(none)${C.reset}`);
    snap.tools.forEach((t, i) => {
      console.log(`  ${t.name}  ${C.dim}~${fmtK(u.toolToks[i] ?? 0)}${C.reset}  ${oneLine(t.description)}`);
      if (opts.full) console.log(indent(JSON.stringify(t.parameters, null, 2)));
    });
  }
  if (show("messages")) {
    console.log(`\n${C.cyan}MESSAGES${C.reset} ${C.dim}(${snap.messages.length})${C.reset}`);
    if (snap.messages.length === 0) console.log(`  ${C.dim}(none)${C.reset}`);
    (snap.messages as any[]).forEach((m) => {
      const { kind, summary } = summarizeMessage(m);
      console.log(`  ${C.dim}[${kind}]${C.reset} ${summary}`);
      if (opts.full) console.log(indent(JSON.stringify(m, null, 2)));
    });
  }
  if (show("blocks")) {
    console.log(`\n${C.cyan}BLOCKS${C.reset} ${C.dim}(${snap.blocks.length})${C.reset}`);
    if (snap.blocks.length === 0) console.log(`  ${C.dim}(none)${C.reset}`);
    (snap.blocks as any[]).forEach((b) => {
      const { kind, summary } = summarizeBlock(b);
      console.log(`  ${C.dim}[${kind}]${C.reset} ${summary}`);
      if (opts.full) console.log(indent(JSON.stringify(b, null, 2)));
    });
  }
  console.log("");
}
