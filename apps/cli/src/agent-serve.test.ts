import { afterAll, beforeAll, expect, test } from "bun:test";
import { mkdtemp, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Value } from "typebox/value";
import { AgentMethods, AgentSchemas } from "@openox/protocol/agent";
import { AgentClient, AgentRPCError } from "./agent-client.ts";
import { AgentServer } from "./agent-serve.ts";

const executable = process.env.OX_AGENT_PI ?? Bun.which("pi");
const timeout = 60000;
const context = { sections: { ox_test: "Always end replies with the word PINEAPPLE" } };
const tools = [{ name: "execute", description: "Run JavaScript on the Ox Host.", parameters: { type: "object", properties: { source: { type: "string" } }, required: ["source"] } }];

let root = "";
let server: AgentServer;
let client: AgentClient;
const notifications: { method: string; params: Record<string, unknown> }[] = [];

function valid(name: keyof typeof AgentSchemas, value: unknown): boolean {
  return Value.Check(AgentSchemas, AgentSchemas[name], value);
}

async function rejection(promise: Promise<unknown>): Promise<AgentRPCError> {
  try { await promise; }
  catch (error) { return error as AgentRPCError; }
  throw new Error("expected the request to fail");
}

beforeAll(async () => {
  root = await realpath(await mkdtemp(join(tmpdir(), "ox-agent-serve-")));
  process.env.PI_CODING_AGENT_SESSION_DIR = join(root, "sessions");
  server = await AgentServer.start({
    cwd: root, approval: "no-approve", executable: executable!, stateDirectory: join(root, "state"), hostname: "127.0.0.1", port: 0,
  });
  client = await AgentClient.connect(server.url);
  client.onNotification = (method, params) => notifications.push({ method, params });
}, timeout);

afterAll(async () => {
  client?.close();
  await server?.stop();
  delete process.env.PI_CODING_AGENT_SESSION_DIR;
  if (root) await rm(root, { recursive: true, force: true });
}, timeout);

test.skipIf(!executable)("serves pi conversations over JSON-RPC", async () => {
  const description = await client.request("agent.describe");
  expect(valid("AgentDescription", description)).toBe(true);
  expect(description.implementation).toMatchObject({ name: "pi" });
  expect(description.folder).toBe(root);
  expect(description.methods).toEqual(Object.keys(AgentMethods));

  const models = await client.request<{ models: unknown[] }>("models.list", {}, timeout);
  expect(valid("AgentModelsResult", models)).toBe(true);
  expect(models.models.length).toBeGreaterThan(0);

  const created = await client.request<{ id: string }>("conversations.new", { context, tools }, timeout);
  expect(valid("AgentNewResult", created)).toBe(true);

  const listed = await client.request<{ conversations: { id: string; origin: string }[] }>("conversations.list");
  expect(valid("AgentConversationsResult", listed)).toBe(true);
  expect(listed.conversations.find((row) => row.id === created.id)?.origin).toBe("ox");

  const opened = await client.request("conversations.open", { id: created.id, context, tools }, timeout);
  expect(valid("AgentOpenResult", opened)).toBe(true);
  expect(opened).toMatchObject({ messages: [], state: "idle" });

  await client.request("conversations.rename", { id: created.id, title: "Agent serve check" });
  const renamed = await client.request<{ conversations: { id: string; title: string }[] }>("conversations.list");
  expect(renamed.conversations.find((row) => row.id === created.id)?.title).toBe("Agent serve check");
  expect(notifications.some((note) => note.method === "conversations.changed" && note.params.title === "Agent serve check")).toBe(true);

  expect(await client.request("conversations.close", { id: created.id })).toEqual({});
  expect((await rejection(client.request("conversations.open", { id: "missing", context, tools }))).code).toBe(-32001);
  expect((await rejection(client.request("conversations.send", { id: created.id }))).code).toBe(-32602);
  expect((await rejection(client.request("conversations.unknown"))).code).toBe(-32601);
}, timeout * 3);
