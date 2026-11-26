import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

export const BRIDGE_ENVIRONMENT = "OX_AGENT_BRIDGE";
export const ORIGIN_ENVIRONMENT = "OX_AGENT_ORIGIN";
export const ORIGIN_ENTRY = "ox.origin";
export const HOST_UNAVAILABLE = "Ox Host is unavailable";

const SOURCE = String.raw`
const bridge = process.env.OX_AGENT_BRIDGE;
const origin = process.env.OX_AGENT_ORIGIN;
const unavailable = "Ox Host is unavailable";

export default async function oxExtension(pi) {
  if (!bridge) return;
  const registered = new Map();
  let applied = [];

  async function sync() {
    const response = await fetch(bridge + "/context");
    if (!response.ok) throw new Error("Ox context request failed with status " + response.status);
    const context = await response.json();
    for (const tool of context.tools) register(tool);
    return context;
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

  if (origin) pi.on("session_start", () => pi.appendEntry(${JSON.stringify(ORIGIN_ENTRY)}, { origin }));

  pi.on("before_agent_start", async (event) => {
    const { sections } = await sync();
    const options = event.systemPromptOptions;
    options.sections = options.sections || {};
    for (const key of applied) if (!Object.hasOwn(sections, key)) delete options.sections[key];
    for (const [key, text] of Object.entries(sections)) options.sections[key] = text;
    applied = Object.keys(sections);
  });
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
