import { runOnce } from "../../../../scripts/debug-ws.ts";
import type { EvalTarget } from "./scorer.ts";

type Model = {
  id: string;
  displayName: string;
  maxTokens: number;
  maxContext: number;
};

type Client = {
  id: string;
  displayName: string;
  supportsTools: boolean;
  models: Model[];
};

export type ResolvedTarget = EvalTarget & {
  supportsTools: boolean;
};

export type EvalTool = {
  name: string;
  description: string;
  parameters: unknown;
};

export type EvalSnapshot = {
  id: string;
  systemPrompt: string;
  tools: EvalTool[];
};

export async function request(envelope: Record<string, unknown>, timeoutMs: number): Promise<Record<string, unknown>> {
  return await runOnce({ ...envelope, id: crypto.randomUUID() }, timeoutMs) as Record<string, unknown>;
}

function resolveTargets(targets: EvalTarget[], clients: Client[]): ResolvedTarget[] {
  return targets.map((target) => {
    const client = clients.find((candidate) => candidate.id === target.client);
    if (!client) throw new Error(`Unknown client ${target.client}; available: ${clients.map((candidate) => candidate.id).join(", ")}`);
    if (typeof client.supportsTools !== "boolean") throw new Error(`Client ${client.id} did not report supportsTools; rebuild and relaunch the current app`);
    if (!client.models.some((model) => model.id === target.model)) {
      throw new Error(`Unknown model ${target.model} for ${client.id}; available: ${client.models.map((model) => model.id).join(", ")}`);
    }
    return { ...target, supportsTools: client.supportsTools };
  });
}

function parseTools(value: unknown): EvalTool[] {
  if (!Array.isArray(value)) return [];
  return value.map((entry) => {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) throw new Error("Eval chat contains an invalid tool declaration");
    const tool = entry as Record<string, unknown>;
    if (typeof tool.name !== "string" || typeof tool.description !== "string") throw new Error("Eval chat contains an incomplete tool declaration");
    return { name: tool.name, description: tool.description, parameters: tool.parameters };
  });
}

export function remainingTimeout(deadline: number | undefined, now = Date.now()): number {
  if (deadline === undefined) return 30_000;
  const remaining = deadline - now;
  if (remaining <= 0) throw new Error("Suite timeout while loading eval context");
  return Math.min(30_000, remaining);
}

export async function loadEvalContext(requestedTargets: EvalTarget[], chat: string, deadline?: number): Promise<{ targets: ResolvedTarget[]; snapshot: EvalSnapshot }> {
  const modelsResult = await request({ kind: "list-models" }, remainingTimeout(deadline));
  if (modelsResult.ok !== true) throw new Error(`Could not list models: ${String(modelsResult.error ?? "unknown error")}`);
  const targets = resolveTargets(requestedTargets, modelsResult.clients as Client[]);
  const chatResult = await request({ kind: "get-chat", sessionId: chat || undefined }, remainingTimeout(deadline));
  if (chatResult.ok !== true || !chatResult.data || typeof chatResult.data !== "object") {
    throw new Error(`Could not load the eval chat: ${String(chatResult.error ?? "no active chat")}`);
  }
  const data = chatResult.data as Record<string, unknown>;
  if (typeof data.id !== "string" || data.id.length === 0) throw new Error("Eval chat has no id");
  const messages = Array.isArray(data.messages) ? data.messages : [];
  if (messages.length > 0) throw new Error(`Eval chat has ${messages.length} messages; use a fresh chat so history does not contaminate system-prompt results`);
  const tools = parseTools(data.tools);
  const chatHasTools = tools.length > 0;
  for (const target of targets) {
    if (target.supportsTools !== chatHasTools) {
      throw new Error(`${target.client}:${target.model} supportsTools=${target.supportsTools}, but the eval chat has tools=${chatHasTools}; select a chat created with the same capability mode`);
    }
  }
  if (typeof data.renderedSystemPrompt !== "string" || data.renderedSystemPrompt.length === 0) throw new Error("Eval chat has no rendered system prompt; rebuild and relaunch the current app");
  return { targets, snapshot: { id: data.id, systemPrompt: data.renderedSystemPrompt, tools } };
}
