export type ToolDecl = { name: string; description: string; parameters: unknown };

export type Snapshot = {
  id: string;
  model: { id: string; maxTokens: number; maxContext: number };
  systemPrompt: string;
  soul: string;
  memory: string;
  tools: ToolDecl[];
  messages: unknown[];
  blocks: unknown[];
  receivedAt?: string;
};

export type SnapshotHeader = Pick<Snapshot, "id" | "model" | "systemPrompt" | "soul" | "memory" | "tools">;
export type SnapshotDelta = Pick<Snapshot, "id" | "messages" | "blocks">;

export type Usage = { input: number; output: number; cachedInput: number; totalTokens: number };

export type ModelEntry = { id: string; displayName: string; maxTokens: number; maxContext: number };
export type ClientEntry = { id: string; displayName: string; regions: string[]; supportsTools: boolean; models: ModelEntry[] };
export type ModelList = { clients: ClientEntry[] };

export type AgentRunResult = {
  ok: boolean;
  client?: { id: string; displayName: string };
  model?: ModelEntry;
  message?: any;
  ttftMs?: number;
  totalMs?: number;
  error?: string;
};

export const estTok = (s: string) => Math.ceil((s?.length ?? 0) / 4);

export function fmtK(n: number): string {
  if (n < 1000) return String(n);
  const k = n / 1000;
  return (k >= 100 ? Math.round(k) : Number(k.toFixed(1))) + "k";
}

export function oneLine(s: string, max = 200): string {
  const flat = s.replace(/\s+/g, " ").trim();
  return flat.length > max ? flat.slice(0, max - 1) + "…" : flat;
}

export function extractCatalog(description: string): { prose: string; fns: Record<string, any> } | null {
  const fence = description.match(/```json\n([\s\S]*?)\n```/);
  if (!fence) return null;
  try {
    const fns = JSON.parse(fence[1]!);
    if (!fns || typeof fns !== "object" || Array.isArray(fns)) return null;
    const prose = (description.slice(0, fence.index) + description.slice(fence.index! + fence[0].length)).trim();
    return { prose, fns };
  } catch {
    return null;
  }
}

// The Swift Message enum encodes nested under its type key (m.user / m.assistant /
// m.toolResult), and a text ContentBlock wraps its string in a TextContent ({text}).
// Read those shapes; fall back to flat fields for forward-compat.
function blockText(blocks: any[]): string | undefined {
  const b = (blocks ?? []).find((x: any) => x?.type === "text");
  if (!b) return undefined;
  return typeof b.text === "string" ? b.text : b.text?.text;
}

export function summarizeMessage(m: any): { kind: string; cls: string; summary: string } {
  if (m?.type === "user" || m?.role === "user") {
    const text = blockText(m.user?.content ?? m.content) ?? "";
    const intent = text.match(/<intent[^>]*>([\s\S]*?)<\/intent>/)?.[1] ?? text;
    return { kind: "user", cls: "user", summary: oneLine(intent) };
  }
  if (m?.type === "assistant" || m?.role === "assistant") {
    const blocks = m.assistant?.content ?? m.content ?? [];
    const text = blockText(blocks);
    const tc = blocks.find((b: any) => b.type === "toolCall" || b.type === "tool_use");
    const summary = text
      ? oneLine(text)
      : tc
        ? `→ ${tc.toolCall?.name ?? tc.name ?? tc.toolName ?? "tool"}`
        : `(${blocks.length} block${blocks.length === 1 ? "" : "s"})`;
    return { kind: "assistant", cls: "assistant", summary };
  }
  if (m?.type === "toolResult" || m?.type === "tool_result" || m?.role === "tool") {
    const tr = m.toolResult ?? m;
    const name = tr.toolName ?? tr.name ?? "tool";
    const error = tr.isError ? " · error" : "";
    return { kind: `toolResult · ${name}`, cls: "toolresult", summary: oneLine(JSON.stringify(tr.content ?? tr.result ?? tr)) + error };
  }
  return { kind: m?.type ?? m?.role ?? "?", cls: "system", summary: oneLine(JSON.stringify(m)) };
}

export function summarizeBlock(b: any): { kind: string; cls: string; summary: string } {
  const kind = b?.kind ?? {};
  const kindKey: string = kind.type ?? "block";
  let summary: string;
  switch (kindKey) {
    case "userText":
    case "system":
      summary = oneLine(kind.text ?? "");
      break;
    case "agentContent": {
      const items: any[] = kind.items ?? [];
      const text = items.filter((it) => it?.text != null).map((it) => it.text).join(" ");
      const artifacts = items.filter((it) => it?.artifact != null);
      const tag = artifacts.length ? ` · ${artifacts.length} artifact${artifacts.length === 1 ? "" : "s"}` : "";
      summary = oneLine(text) + tag;
      break;
    }
    case "confirm":
      summary = oneLine(kind.prompt ?? "");
      break;
    case "stepGroup": {
      const steps: any[] = kind.steps ?? [];
      summary = `${steps.length} step${steps.length === 1 ? "" : "s"}`;
      break;
    }
    default:
      summary = oneLine(JSON.stringify(kind));
  }
  return { kind: kindKey, cls: "system", summary };
}

export function realUsage(messages: any[]): Usage | null {
  for (let i = messages.length - 1; i >= 0; i--) {
    const u: Usage | undefined = messages[i]?.assistant?.usage ?? messages[i]?.usage;
    if (u && (u.input > 0 || u.totalTokens > 0)) return u;
  }
  return null;
}

export type UsageBreakdown = {
  system: number;
  tools: number;
  messages: number;
  toolToks: number[];
  input: number;
  maxCtx: number;
  cached: number;
  estimated: boolean;
};

export function usageBreakdown(snap: Snapshot): UsageBreakdown {
  const toolToksRaw = (snap.tools ?? []).map((t) => estTok(JSON.stringify(t)));
  const raw = {
    system: estTok(snap.systemPrompt) + estTok(snap.soul) + estTok(snap.memory),
    tools: toolToksRaw.reduce((a, b) => a + b, 0),
    messages: (snap.messages ?? []).reduce((a: number, m) => a + estTok(JSON.stringify(m)), 0),
  };
  const usage = realUsage((snap.messages ?? []) as any[]);
  const estTotalRaw = raw.system + raw.tools + raw.messages;
  const scale = usage && estTotalRaw > 0 ? usage.input / estTotalRaw : 1;
  const system = Math.round(raw.system * scale);
  const tools = Math.round(raw.tools * scale);
  const messages = Math.round(raw.messages * scale);
  const input = usage?.input ?? system + tools + messages;
  const maxCtx = snap.model.maxContext || input || 1;
  return {
    system,
    tools,
    messages,
    toolToks: toolToksRaw.map((t) => Math.round(t * scale)),
    input,
    maxCtx,
    cached: usage?.cachedInput ?? 0,
    estimated: !usage,
  };
}
