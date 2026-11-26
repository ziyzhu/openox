import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

export const BRIDGE_ENVIRONMENT = "OX_AGENT_BRIDGE";
export const HOST_UNAVAILABLE = "Ox Host is unavailable";

const SOURCE = String.raw`
const bridge = process.env.OX_AGENT_BRIDGE;
const unavailable = "Ox Host is unavailable";
const builtin = new Set(["read", "bash", "edit", "write", "grep", "find", "ls"]);

export default async function oxExtension(pi) {
  if (!bridge) return;
  const registered = new Map();
  let applied = [];
  let allowed = new Set();
  let confirmed = new Set();

  async function sync() {
    const response = await fetch(bridge + "/context");
    if (!response.ok) throw new Error("Ox context request failed with status " + response.status);
    const context = await response.json();
    for (const tool of context.tools) register(tool);
    allowed = new Set(context.agentTools || []);
    confirmed = new Set(context.confirmTools || []);
    return context;
  }

  function activate() {
    const kept = pi.getActiveTools().filter((name) => !builtin.has(name));
    pi.setActiveTools([...new Set([...kept, ...allowed])]);
  }

  function register(tool) {
    const signature = JSON.stringify(tool);
    if (registered.get(tool.name) === signature) return;
    registered.set(tool.name, signature);
    pi.registerTool({
      name: tool.name,
      label: tool.name,
      description: tool.description,
      parameters: tool.parameters,
      execute: (toolCallId, args, signal, onUpdate) => callHost(tool.name, toolCallId, args, signal, onUpdate),
    });
  }

  await sync();

  pi.on("session_start", () => activate());

  pi.on("tool_call", async (event, ctx) => {
    if (builtin.has(event.toolName) && !allowed.has(event.toolName)) {
      return { block: true, reason: event.toolName + " is turned off for this conversation in Ox" };
    }
    if (!confirmed.has(event.toolName)) return undefined;
    const ok = await ctx.ui.confirm("Allow " + event.toolName + "?", describe(event));
    return ok ? undefined : { block: true, reason: "The user declined this " + event.toolName + " call" };
  });

  pi.on("before_agent_start", async (event) => {
    const { sections } = await sync();
    activate();
    const options = event.systemPromptOptions;
    options.sections = options.sections || {};
    for (const key of applied) if (!Object.hasOwn(sections, key)) delete options.sections[key];
    for (const [key, text] of Object.entries(sections)) options.sections[key] = text;
    applied = Object.keys(sections);
  });
}

function describe(event) {
  const input = event.input || {};
  const text = typeof input.command === "string" ? input.command : JSON.stringify(input);
  return text.length > 2000 ? text.slice(0, 1999) + "…" : text;
}

async function callHost(name, toolCallId, args, signal, onUpdate) {
  let response;
  try {
    response = await fetch(bridge + "/tools/call", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ toolCallId, name, args }),
      signal,
    });
  } catch (error) {
    if (signal && signal.aborted) throw error;
    throw new Error(unavailable);
  }
  if (!response.ok || !response.body) throw new Error((await response.text().catch(() => "")) || unavailable);
  const decoder = new TextDecoder();
  let buffer = "";
  for await (const chunk of response.body) {
    buffer += decoder.decode(chunk, { stream: true });
    for (let newline = buffer.indexOf("\n"); newline !== -1; newline = buffer.indexOf("\n")) {
      const record = JSON.parse(buffer.slice(0, newline));
      buffer = buffer.slice(newline + 1);
      if (record.type === "progress" && onUpdate) onUpdate({ content: [{ type: "text", text: record.message }], details: undefined });
      if (record.type === "result") return { content: record.content, details: undefined, isError: record.isError === true };
    }
  }
  throw new Error(unavailable);
}
`;

export async function writePiExtension(directory: string): Promise<string> {
  await mkdir(directory, { recursive: true });
  const path = join(directory, "ox-pi-extension.js");
  await writeFile(path, SOURCE.trimStart());
  return path;
}
