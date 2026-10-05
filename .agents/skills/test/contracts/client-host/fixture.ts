import { validateParams, validateResult } from "../../../../../packages/protocol/src/index.ts";

const chatId = "standalone-smoke";
const text = "Hello from the fixture.";
const snapshot = {
  id: chatId, model: { id: "mock", maxTokens: 8192, maxContext: 1000000 },
  systemPrompt: "Fixture", renderedSystemPrompt: "Fixture", soul: "", memory: "", tools: [],
  messages: [{ role: "assistant", content: [{ type: "text", text }] }], blocks: [], isBusy: false,
};
const results: Record<string, unknown> = {
  "host.describe": {
    implementation: { name: "Ox fixture", version: "1", build: "1" }, protocols: { repository: [3] },
    methods: ["host.describe", "chats.list", "chats.new", "chats.send", "chats.get"],
  },
  "chats.list": { chats: [{ id: chatId, title: "Standalone smoke test", model: null,
    createdAt: "2026-09-22T00:00:00Z", lastActivity: null, active: false }] },
  "chats.new": { chatId, temporary: true, model: "mock:mock" },
  "chats.send": { chatId, outcome: "completed", text },
  "chats.get": { data: snapshot },
};

// Fixture transport only: real CLI processes and shared contract validation exercise the boundary.
export function hostFixtureReply(request: { jsonrpc?: string; id?: string | number; method: string; params?: Record<string, unknown> }) {
  const reply = { jsonrpc: "2.0", id: request.id ?? null };
  if (request.jsonrpc !== "2.0") return { ...reply, error: { code: -32600, message: "Invalid Request" } };
  if (!(request.method in results)) return { ...reply, error: { code: -32601, message: "Method not found" } };
  if (!validateParams(request.method, request.params ?? {})) return { ...reply, error: { code: -32602, message: "Invalid params" } };
  if (request.method === "chats.new" && request.params?.providerId !== undefined && request.params.providerId !== "mock") {
    return { ...reply, error: { code: -32000, message: "fixture rejected provider" } };
  }
  const result = results[request.method];
  if (!validateResult(request.method, result)) throw new Error(`Invalid fixture result: ${request.method}`);
  return { ...reply, result };
}
