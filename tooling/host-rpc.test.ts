import { afterEach, expect, test } from "bun:test";
import { HostConnection, HostRPCError } from "../apps/cli/src/host-connection.ts";
import { HostRPCClient } from "../apps/cli/src/host-rpc.ts";

const cleanups: (() => void)[] = [];
afterEach(() => { for (const cleanup of cleanups.splice(0).reverse()) cleanup(); });

function serve(receive: (request: any, send: (value: unknown) => void, raw: (text: string) => void) => void): string {
  const server = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    fetch(request, server) { return server.upgrade(request) ? undefined : new Response(null, { status: 400 }); },
    websocket: {
      message(socket, bytes) {
        receive(JSON.parse(String(bytes)), value => socket.send(JSON.stringify(value)), text => socket.send(text));
      },
    },
  });
  cleanups.push(() => server.stop(true));
  return `ws://127.0.0.1:${server.port}`;
}

function client(endpoint: string): HostRPCClient {
  const value = new HostRPCClient(endpoint);
  cleanups.push(() => value.close());
  return value;
}

function transport(endpoint: string) {
  const connection = new HostConnection(endpoint);
  cleanups.push(() => connection.close());
  return {
    call: (method: string, timeoutMs: number) => connection.request(method, {}, timeoutMs),
    close: () => connection.close(),
  };
}

const description = {
  implementation: { name: "Ox", version: "1.0.7", build: "1" },
  methods: { "host.describe": 1, "chats.list": 1 },
};
const row = { id: "chat", title: "Example", model: null, createdAt: "2026-09-22T00:00:00Z", lastActivity: null, active: true };

test("chat listing discovers compatibility and preserves nullable fields", async () => {
  const methods: string[] = [];
  const endpoint = serve((request, send) => {
    methods.push(request.method);
    send({ jsonrpc: "2.0", id: request.id, result: request.method === "host.describe" ? description : { chats: [row] } });
  });
  expect(await client(endpoint).listChats(1000)).toEqual([row]);
  expect(methods).toEqual(["host.describe", "chats.list"]);
});

test("incompatible chat contract fails before the operation is sent", async () => {
  const methods: string[] = [];
  const endpoint = serve((request, send) => {
    methods.push(request.method);
    send({ jsonrpc: "2.0", id: request.id, result: { ...description, methods: { "host.describe": 1, "chats.list": 2 } } });
  });
  await expect(client(endpoint).listChats(1000)).rejects.toThrow("chats.list contract 1");
  expect(methods).toEqual(["host.describe"]);
});

test("invalid chat payload is rejected", async () => {
  const endpoint = serve((request, send) => {
    send({ jsonrpc: "2.0", id: request.id, result: request.method === "host.describe" ? description : { chats: [{ ...row, active: "yes" }] } });
  });
  await expect(client(endpoint).listChats(1000)).rejects.toThrow("invalid chat list");
});

test("concurrent RPC results are correlated even when returned out of order", async () => {
  let first: any;
  const endpoint = serve((request, send) => {
    if (!first) { first = request; return; }
    send({ jsonrpc: "2.0", id: request.id, result: 2 });
    send({ jsonrpc: "2.0", id: first.id, result: 1 });
  });
  const connection = transport(endpoint);
  expect(await Promise.all([connection.call("first", 1000), connection.call("second", 1000)])).toEqual([1, 2]);
});

test("RPC errors retain their code and data", async () => {
  const endpoint = serve((request, send) => send({
    jsonrpc: "2.0", id: request.id, error: { code: -32601, message: "Method not found", data: { method: request.method } },
  }));
  const error = await transport(endpoint).call("missing", 1000).catch(error => error);
  expect(error).toBeInstanceOf(HostRPCError);
  if (!(error instanceof HostRPCError)) throw new Error("Expected an RPC error");
  expect(error.code).toBe(-32601);
  expect(error.data).toEqual({ method: "missing" });
});

test.each([
  { result: null, error: { code: -32603, message: "error" } },
  {},
  { error: { code: "-32603", message: "error" } },
  { error: { code: -32603, message: 12 } },
  { jsonrpc: "1.0", result: null },
])("malformed RPC envelope fails promptly: %j", async fields => {
  const endpoint = serve((request, send) => send({ jsonrpc: "2.0", id: request.id, ...fields }));
  await expect(transport(endpoint).call("host.describe", 1000)).rejects.toThrow("invalid JSON-RPC response");
});

test("unparseable responses fail all pending calls without waiting for timeouts", async () => {
  const endpoint = serve((_request, _send, raw) => raw("{"));
  const connection = transport(endpoint);
  const results = await Promise.allSettled([connection.call("first", 1000), connection.call("second", 1000)]);
  expect(results.map(result => result.status === "rejected" ? result.reason.message : "success")).toEqual([
    "Host returned malformed JSON", "Host returned malformed JSON",
  ]);
});

test("legacy-only Hosts report an actionable compatibility failure", async () => {
  const endpoint = serve((_request, send) => send({ kind: "error", error: "invalid envelope" }));
  await expect(transport(endpoint).call("host.describe", 1000)).rejects.toThrow("update the Host");
});

test("old success envelopes are rejected rather than interpreted as RPC results", async () => {
  const endpoint = serve((request, send) => send({ id: request.id, kind: "get-logs-result", ok: true, logs: [] }));
  await expect(transport(endpoint).call("logs.list", 1000)).rejects.toThrow("invalid JSON-RPC response");
});

test("timeouts do not retry requests and close rejects pending work", async () => {
  let requests = 0;
  const endpoint = serve(() => { requests++; });
  const connection = transport(endpoint);
  await expect(connection.call("slow", 100)).rejects.toThrow("timeout");
  expect(requests).toBe(1);
  const pending = connection.call("pending", 1000);
  connection.close();
  await expect(pending).rejects.toThrow("connection closed");
});

const liveEndpoint = process.env.OX_RPC_TEST_ENDPOINT;
test.skipIf(!liveEndpoint)("live Host methods, errors, notifications, batches and rejection of the old protocol", async () => {
  const endpoint = liveEndpoint!;
  const host = client(endpoint);
  expect((await host.describe(5000)).methods).toMatchObject(description.methods);
  const chats = await host.listChats(5000);
  expect((await host.call("vm.inspect", 5000)).value).toBeDefined();
  expect((await host.call("models.list", 5000)).clients).toBeArray();
  expect((await host.call("logs.list", 5000)).logs).toBeArray();
  expect((await host.call("services.list", 30000)).services).toBeArray();
  await expect(host.call("debug.providers.setKey", 5000)).rejects.toMatchObject({ code: -32602 });
  await expect(host.call("vm.functions", 5000, { function: "ox.missing" })).rejects.toMatchObject({ code: -32000 });
  await expect(host.call("agents.run", 5000, { clientId: "missing", modelId: "missing" })).rejects.toMatchObject({ code: -32000 });
  const socket = new WebSocket(endpoint);
  cleanups.push(() => socket.close());
  await new Promise<void>((resolve, reject) => { socket.onopen = () => resolve(); socket.onerror = reject; });
  const exchange = (payload: string): Promise<any> => new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("live RPC response timed out")), 5000);
    socket.onmessage = event => { clearTimeout(timer); resolve(JSON.parse(String(event.data))); };
    socket.send(payload);
  });
  expect((await exchange(JSON.stringify({ kind: "list-chats", id: "old" }))).error.code).toBe(-32600);
  expect((await exchange("{")).error.code).toBe(-32700);
  expect((await exchange("[]")).error.code).toBe(-32600);
  expect((await exchange(JSON.stringify({ jsonrpc: "2.0", method: "missing", id: 7 }))).error.code).toBe(-32601);
  expect((await exchange(JSON.stringify({ jsonrpc: "2.0", method: "chats.list", params: { extra: true }, id: "params" }))).error.code).toBe(-32602);
  expect((await exchange(JSON.stringify({ jsonrpc: "2.0", method: "chats.list", id: true }))).id).toBeNull();
  const responses = await exchange(JSON.stringify([
    { jsonrpc: "2.0", method: "host.describe" },
    { jsonrpc: "2.0", method: "missing" },
    { jsonrpc: "2.0", method: "chats.list", id: 12 },
    { jsonrpc: "2.0", method: "host.describe", id: null },
    { invalid: true },
  ]));
  expect(responses).toHaveLength(3);
  expect(responses[0].id).toBe(12);
  expect(responses[0].result.chats).toEqual(chats);
  expect(responses[1].id).toBeNull();
  expect(responses[1].result.methods).toMatchObject(description.methods);
  expect(responses[2].error.code).toBe(-32600);
  socket.send(JSON.stringify([{ jsonrpc: "2.0", method: "host.describe" }]));
  const next = await exchange(JSON.stringify({ jsonrpc: "2.0", method: "host.describe", id: "after-notification" }));
  expect(next.id).toBe("after-notification");
}, 60000);
