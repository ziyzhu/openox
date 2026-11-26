import { afterAll, beforeAll, expect, test } from "bun:test";
import { mkdir, mkdtemp, realpath, rm } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { Value } from "typebox/value";
import { AgentMethods, AgentSchemas } from "@openox/protocol/agent";
import { AgentClient, AgentRPCError } from "./agent-client.ts";
import { piCommand } from "./agent-pi.ts";
import { AgentServer } from "./agent-serve.ts";
import { admission } from "./agent-tailscale.ts";

const pi = (() => { try { return piCommand(); } catch { return undefined; } })();
const timeout = 60000;
const context = { sections: { ox_test: "Always end replies with the word PINEAPPLE" } };
const tools = [{ name: "execute", description: "Run JavaScript on the Ox Host.", parameters: { type: "object", properties: { source: { type: "string" } }, required: ["source"] } }];

let root = "";
let home = "";
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
  home = await realpath(homedir());
  await mkdir(join(root, "project", "nested"), { recursive: true });
  process.env.PI_CODING_AGENT_SESSION_DIR = join(root, "sessions");
  server = await AgentServer.start({
    approval: "no-approve", pi: pi!, stateDirectory: join(root, "state"), port: 0,
    eventLimits: { events: 4, bytes: 1024 * 1024 },
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

test.skipIf(!pi)("serves pi conversations over JSON-RPC", async () => {
  const description = await client.request("agent.describe");
  expect(valid("AgentDescription", description)).toBe(true);
  expect(description.implementation).toMatchObject({ name: "pi" });
  expect(description.cwd).toBe(home);
  expect(description.methods).toEqual(Object.keys(AgentMethods));

  const models = await client.request<{ models: unknown[] }>("models.list", {}, timeout);
  expect(valid("AgentModelsResult", models)).toBe(true);
  expect(models.models.length).toBeGreaterThan(0);

  const created = await client.request<{ id: string }>("conversations.new", { context, tools }, timeout);
  expect(valid("AgentNewResult", created)).toBe(true);

  const listed = await client.request<{ conversations: { id: string; origin: string; cwd: string }[] }>("conversations.list");
  expect(valid("AgentConversationsResult", listed)).toBe(true);
  expect(listed.conversations.find((row) => row.id === created.id)).toMatchObject({ origin: "ox", cwd: home });
  expect(created).toMatchObject({ cwd: home });

  const opened = await client.request("conversations.open", { id: created.id, context, tools }, timeout);
  expect(valid("AgentOpenResult", opened)).toBe(true);
  expect(opened).toMatchObject({ messages: [], state: "idle" });
  expect(opened.replay).toBeUndefined();

  await client.request("conversations.rename", { id: created.id, title: "Agent serve check" });
  const renamed = await client.request<{ conversations: { id: string; title: string }[] }>("conversations.list");
  expect(renamed.conversations.find((row) => row.id === created.id)?.title).toBe("Agent serve check");
  expect(notifications.some((note) => note.method === "conversations.changed" && note.params.title === "Agent serve check")).toBe(true);

  expect(await client.request("conversations.close", { id: created.id })).toEqual({});
  expect((await rejection(client.request("conversations.open", { id: "missing", context, tools }))).code).toBe(-32001);
  expect((await rejection(client.request("conversations.send", { id: created.id }))).code).toBe(-32602);
  expect((await rejection(client.request("conversations.unknown"))).code).toBe(-32601);
}, timeout * 3);

test.skipIf(!pi)("creates conversations in any existing folder", async () => {
  const nested = await client.request<{ id: string; cwd: string }>("conversations.new", { cwd: join(root, "project", "nested"), context, tools }, timeout);
  expect(nested.cwd).toBe(join(root, "project", "nested"));
  await client.request("conversations.rename", { id: nested.id, title: "Nested" });
  const listed = await client.request<{ conversations: { id: string; cwd: string }[] }>("conversations.list");
  expect(listed.conversations.find((row) => row.id === nested.id)?.cwd).toBe(join(root, "project", "nested"));

  const tilde = await client.request<{ cwd: string }>("conversations.new", { cwd: "~", context, tools }, timeout);
  expect(tilde.cwd).toBe(home);
  const missing = await rejection(client.request("conversations.new", { cwd: join(root, "missing"), context, tools }));
  expect(missing).toMatchObject({ code: -32602, message: "folder does not exist" });
  expect((await rejection(client.request("folders.list"))).code).toBe(-32601);
}, timeout * 2);

test.skipIf(!pi)("replays buffered events after the open result", async () => {
  const created = await client.request<{ id: string }>("conversations.new", { context, tools }, timeout);
  for (const title of ["one", "two", "three", "four", "five", "six"]) await client.request("conversations.rename", { id: created.id, title });
  const events = notifications.filter((note) => note.method === "conversations.event" && note.params.id === created.id).map((note) => note.params.seq);
  expect(events).toEqual([1, 2, 3, 4, 5, 6]);

  const reconnect = async (since: number) => {
    const other = await AgentClient.connect(server.url);
    const received: { seq: unknown; afterResult: boolean }[] = [];
    let answered = false;
    other.onNotification = (method, params) => {
      if (method === "conversations.event" && params.id === created.id) received.push({ seq: params.seq, afterResult: answered });
    };
    const result = await other.request<{ seq: number; replay: string }>("conversations.open", { id: created.id, context, tools, since }, timeout)
      .finally(() => { answered = true; });
    await Bun.sleep(100);
    other.close();
    return { result, received };
  };

  const complete = await reconnect(4);
  expect(valid("AgentOpenResult", complete.result)).toBe(true);
  expect(complete.result).toMatchObject({ seq: 6, replay: "complete" });
  expect(complete.received).toEqual([{ seq: 5, afterResult: true }, { seq: 6, afterResult: true }]);

  const gap = await reconnect(0);
  expect(gap.result).toMatchObject({ seq: 6, replay: "gap" });
  expect(gap.received.map((event) => event.seq)).toEqual([3, 4, 5, 6]);

  const future = await reconnect(9);
  expect(future.result).toMatchObject({ seq: 6, replay: "gap" });
  expect(future.received).toEqual([]);
}, timeout * 2);

test("admits loopback processes and the tailnet owner only", () => {
  const tailnet = { name: "mac.example.ts.net", login: "owner@example.com" };
  const check = (headers: Record<string, string>) => admission(new Headers(headers), 9878, tailnet);
  const local = (headers: Record<string, string>) => admission(new Headers(headers), 9878, undefined);
  expect(check({ host: "127.0.0.1:9878" })).toEqual({ kind: "allowed", via: "loopback" });
  expect(local({ host: "localhost:9878" })).toEqual({ kind: "allowed", via: "loopback" });
  expect(check({ host: "mac.example.ts.net:9878", "tailscale-user-login": "owner@example.com" })).toEqual({ kind: "allowed", via: "tailnet" });
  expect(check({ host: "mac.example.ts.net:9878", "tailscale-user-login": "guest@example.com" })).toEqual({ kind: "rejected", reason: "not_owner" });
  expect(check({ host: "mac.example.ts.net:9878" })).toEqual({ kind: "rejected", reason: "missing_identity" });
  expect(local({ host: "mac.example.ts.net:9878", "tailscale-user-login": "owner@example.com" })).toEqual({ kind: "rejected", reason: "unknown_host" });
  expect(check({ host: "127.0.0.1:9878", "tailscale-user-login": "owner@example.com" })).toEqual({ kind: "rejected", reason: "forwarded_loopback" });
  expect(check({ host: "127.0.0.1:9878", "x-forwarded-for": "100.64.0.9" })).toEqual({ kind: "rejected", reason: "forwarded_loopback" });
  expect(check({ host: "127.0.0.1:9999" })).toEqual({ kind: "rejected", reason: "unknown_host" });
  expect(check({ host: "evil.example" })).toEqual({ kind: "rejected", reason: "unknown_host" });
  expect(check({})).toEqual({ kind: "rejected", reason: "unknown_host" });
});

test.skipIf(!pi)("serves health and rejects foreign hosts", async () => {
  const url = server.url.replace("ws://", "http://");
  expect(await (await fetch(`${url}/health`)).json()).toEqual({ name: "ox-agent", protocol: 1 });
  expect((await fetch(`${url}/health`, { headers: { host: "evil.example" } })).status).toBe(403);
});
