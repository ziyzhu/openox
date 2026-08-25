export type ToolDeclaration = { name: string; description: string; parameters: unknown };

export type ChatSnapshot = {
  id: string;
  model: { id: string; maxTokens: number; maxContext: number };
  systemPrompt: string;
  renderedSystemPrompt?: string;
  soul: string;
  memory: string;
  tools: ToolDeclaration[];
  messages: unknown[];
  blocks: unknown[];
};

export type ModelEntry = { id: string; displayName: string; maxTokens: number; maxContext: number };
export type ClientEntry = { id: string; displayName: string; regions: string[]; supportsTools: boolean; models: ModelEntry[] };

export type AgentRunResult = {
  ok: boolean;
  client?: { id: string; displayName: string };
  model?: ModelEntry;
  message?: any;
  ttftMs?: number;
  totalMs?: number;
  error?: string;
};

type Usage = { input: number; output: number; cachedInput: number; totalTokens: number };

export type UsageBreakdown = {
  system: number;
  tools: number;
  messages: number;
  toolTokens: number[];
  input: number;
  maximumContext: number;
  cached: number;
  estimated: boolean;
};

export function formatTokenCount(value: number): string {
  if (value < 1000) return String(value);
  const thousands = value / 1000;
  return `${thousands >= 100 ? Math.round(thousands) : Number(thousands.toFixed(1))}k`;
}

export function oneLine(value: string, maximumLength = 200): string {
  const flattened = value.replace(/\s+/gu, " ").trim();
  return flattened.length > maximumLength ? `${flattened.slice(0, maximumLength - 1)}…` : flattened;
}

function estimateTokens(value: string): number {
  return Math.ceil((value?.length ?? 0) / 4);
}

function blockText(blocks: any[]): string | undefined {
  const block = (blocks ?? []).find((candidate: any) => candidate?.type === "text");
  if (!block) return undefined;
  return typeof block.text === "string" ? block.text : block.text?.text;
}

export function summarizeMessage(message: any): { kind: string; summary: string } {
  if (message?.type === "user" || message?.role === "user") {
    const text = blockText(message.user?.content ?? message.content) ?? "";
    const intent = text.match(/<intent[^>]*>([\s\S]*?)<\/intent>/u)?.[1] ?? text;
    return { kind: "user", summary: oneLine(intent) };
  }
  if (message?.type === "assistant" || message?.role === "assistant") {
    const blocks = message.assistant?.content ?? message.content ?? [];
    const text = blockText(blocks);
    const toolCall = blocks.find((block: any) => block.type === "toolCall" || block.type === "tool_use");
    const summary = text
      ? oneLine(text)
      : toolCall
        ? `→ ${toolCall.toolCall?.name ?? toolCall.name ?? toolCall.toolName ?? "tool"}`
        : `(${blocks.length} block${blocks.length === 1 ? "" : "s"})`;
    return { kind: "assistant", summary };
  }
  if (message?.type === "toolResult" || message?.type === "tool_result" || message?.role === "tool") {
    const result = message.toolResult ?? message;
    const name = result.toolName ?? result.name ?? "tool";
    const error = result.isError ? " · error" : "";
    return { kind: `toolResult · ${name}`, summary: `${oneLine(JSON.stringify(result.content ?? result.result ?? result))}${error}` };
  }
  return { kind: message?.type ?? message?.role ?? "?", summary: oneLine(JSON.stringify(message)) };
}

export function summarizeBlock(block: any): { kind: string; summary: string } {
  const value = block?.kind ?? {};
  const kind: string = value.type ?? "block";
  if (kind === "userText" || kind === "system") return { kind, summary: oneLine(value.text ?? "") };
  if (kind === "agentContent") {
    const items: any[] = value.items ?? [];
    const text = items.filter(item => item?.text != null).map(item => item.text).join(" ");
    const artifacts = items.filter(item => item?.artifact != null).length;
    return { kind, summary: `${oneLine(text)}${artifacts ? ` · ${artifacts} artifact${artifacts === 1 ? "" : "s"}` : ""}` };
  }
  if (kind === "confirm") return { kind, summary: oneLine(value.prompt ?? "") };
  if (kind === "stepGroup") {
    const count = Array.isArray(value.steps) ? value.steps.length : 0;
    return { kind, summary: `${count} step${count === 1 ? "" : "s"}` };
  }
  return { kind, summary: oneLine(JSON.stringify(value)) };
}

function realUsage(messages: any[]): Usage | undefined {
  for (let index = messages.length - 1; index >= 0; index--) {
    const usage: Usage | undefined = messages[index]?.assistant?.usage ?? messages[index]?.usage;
    if (usage && (usage.input > 0 || usage.totalTokens > 0)) return usage;
  }
}

export function usageBreakdown(snapshot: ChatSnapshot): UsageBreakdown {
  const rawToolTokens = (snapshot.tools ?? []).map(tool => estimateTokens(JSON.stringify(tool)));
  const raw = {
    system: estimateTokens(snapshot.systemPrompt) + estimateTokens(snapshot.soul) + estimateTokens(snapshot.memory),
    tools: rawToolTokens.reduce((left, right) => left + right, 0),
    messages: (snapshot.messages ?? []).reduce((total: number, message) => total + estimateTokens(JSON.stringify(message)), 0),
  };
  const usage = realUsage((snapshot.messages ?? []) as any[]);
  const estimatedTotal = raw.system + raw.tools + raw.messages;
  const scale = usage && estimatedTotal > 0 ? usage.input / estimatedTotal : 1;
  const system = Math.round(raw.system * scale);
  const tools = Math.round(raw.tools * scale);
  const messages = Math.round(raw.messages * scale);
  const input = usage?.input ?? system + tools + messages;
  return {
    system,
    tools,
    messages,
    toolTokens: rawToolTokens.map(value => Math.round(value * scale)),
    input,
    maximumContext: snapshot.model.maxContext || input || 1,
    cached: usage?.cachedInput ?? 0,
    estimated: !usage,
  };
}
