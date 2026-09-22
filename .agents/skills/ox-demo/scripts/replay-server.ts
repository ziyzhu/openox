import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const prompts = [
  ["Compare desks on Facebook Marketplace, Amazon, and Reddit.", "01-desks.md"],
  ["Plan a Seattle weekend with Airbnb, Google, and Xiaohongshu.", "02-seattle.md"],
  ["What should I catch up on in Outlook and LinkedIn?", "03-catch-up.md"],
] as const;

const args = process.argv.slice(2);
const option = (name: string, fallback?: string) => {
  const index = args.indexOf(name);
  const value = index < 0 ? fallback : args[index + 1];
  if (!value) throw new Error(`Missing ${name}`);
  return value;
};

const responseDirectory = resolve(option("--responses"));
const port = Number(option("--port", "8082"));
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("Invalid port");

const responses = new Map(prompts.map(([prompt, file]) => [
  prompt,
  readFileSync(resolve(responseDirectory, file), "utf8").trimEnd(),
]));
const modelID = "bonsai-demo-replay";
const encoder = new TextEncoder();

function latestPrompt(payload: any): string | undefined {
  const messages = Array.isArray(payload.messages) ? payload.messages : [];
  const user = messages.findLast((message: any) => message?.role === "user");
  const content = user?.content;
  if (typeof content === "string") return content.trim();
  if (Array.isArray(content)) return content.filter((part: any) => part?.type === "text").map((part: any) => part.text).join("").trim();
  return undefined;
}

function event(id: string, delta: Record<string, unknown>, finishReason: string | null = null): string {
  return `data: ${JSON.stringify({
    id,
    object: "chat.completion.chunk",
    created: Math.floor(Date.now() / 1000),
    model: modelID,
    choices: [{ index: 0, delta, finish_reason: finishReason }],
  })}\n\n`;
}

function streamResponse(text: string, signal: AbortSignal): Response {
  const id = `demo-${crypto.randomUUID()}`;
  const chunks = text.match(/[\s\S]{1,20}/g) ?? [];
  const delay = Math.min(180, Math.max(22, Math.ceil(4500 / chunks.length)));
  const body = new ReadableStream<Uint8Array>({
    async start(controller) {
      const send = (value: string) => controller.enqueue(encoder.encode(value));
      send(event(id, { role: "assistant", content: "" }));
      for (const chunk of chunks) {
        if (signal.aborted) {
          controller.close();
          return;
        }
        send(event(id, { content: chunk }));
        await Bun.sleep(delay);
      }
      send(event(id, {}, "stop"));
      send("data: [DONE]\n\n");
      controller.close();
    },
  });
  return new Response(body, {
    headers: { "content-type": "text/event-stream", "cache-control": "no-cache" },
  });
}

Bun.serve({
  hostname: "127.0.0.1",
  port,
  idleTimeout: 0,
  async fetch(request) {
    const path = new URL(request.url).pathname;
    if (request.method === "GET" && path === "/health") return Response.json({ status: "ok", prompts: responses.size });
    if (request.method === "GET" && path === "/v1/models") {
      return Response.json({
        object: "list",
        data: [{
          id: modelID,
          name: "Bonsai 2 27B",
          object: "model",
          owned_by: "local",
          context_length: 65536,
          top_provider: { max_completion_tokens: 8192 },
          supported_parameters: ["tools", "tool_choice", "temperature", "top_p", "max_tokens"],
        }],
      });
    }
    if (request.method !== "POST" || path !== "/v1/chat/completions") return Response.json({ error: "Unknown endpoint" }, { status: 404 });
    const payload = await request.json() as any;
    if (payload.model !== modelID) return Response.json({ error: "Unknown model" }, { status: 400 });
    const prompt = latestPrompt(payload);
    const matches = prompts.filter(([value]) => prompt === value);
    console.log(JSON.stringify({ event: "request", userChars: prompt?.length ?? 0, matches: matches.length }));
    const content = matches.length === 1 ? responses.get(matches[0][0]) : undefined;
    if (!content) return Response.json({ error: "No saved response for this prompt" }, { status: 422 });
    console.log(JSON.stringify({ event: "replay", prompt: prompts.findIndex(([value]) => value === matches[0][0]) + 1, stream: payload.stream === true }));
    if (payload.stream === true) return streamResponse(content, request.signal);
    return Response.json({
      id: `demo-${crypto.randomUUID()}`,
      object: "chat.completion",
      created: Math.floor(Date.now() / 1000),
      model: modelID,
      choices: [{ index: 0, message: { role: "assistant", content }, finish_reason: "stop" }],
    });
  },
});

console.log(JSON.stringify({ event: "ready", port, prompts: responses.size }));
