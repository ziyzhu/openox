import { afterEach, expect, test } from "bun:test";
import { HostConnection, HostRPCError } from "../../apps/cli/src/host-connection.ts";
import { HostRPCClient } from "../../apps/cli/src/host-rpc.ts";
import { qaConfig } from "../qa-config.ts";

const cleanups: (() => void)[] = [];
afterEach(() => { for (const cleanup of cleanups.splice(0).reverse()) cleanup(); });

function serve(receive: (request: any, send: (value: unknown) => void, raw: (text: string) => void, close: () => void) => void): string {
  const server = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    fetch(request, server) { return server.upgrade(request) ? undefined : new Response(null, { status: 400 }); },
    websocket: {
      message(socket, bytes) {
        receive(JSON.parse(String(bytes)), value => socket.send(JSON.stringify(value)), text => socket.send(text), () => socket.close());
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
  protocols: { repository: [3] },
  methods: ["host.describe", "chats.list"],
};
const row = { id: "chat", title: "Example", model: null, createdAt: "2026-09-22T00:00:00Z", lastActivity: null, active: true };

test("chat listing preserves nullable fields without a discovery round trip", async () => {
  const methods: string[] = [];
  const endpoint = serve((request, send) => {
    methods.push(request.method);
    send({ jsonrpc: "2.0", id: request.id, result: request.method === "host.describe" ? description : { chats: [row] } });
  });
  const host = client(endpoint);
  expect(await host.listChats(1000)).toEqual([row]);
  expect(await host.listChats(1000)).toEqual([row]);
  expect(methods).toEqual(["chats.list", "chats.list"]);
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
    expect.stringContaining("Host returned malformed JSON. Request outcome unknown"),
    expect.stringContaining("Host returned malformed JSON. Request outcome unknown"),
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
  const error = await connection.call("slow", 100).catch(error => error);
  if (!(error instanceof Error)) throw new Error("Expected a timeout error");
  expect(error.message).toContain("timeout");
  expect(error.message).toContain("Request outcome unknown");
  expect(requests).toBe(1);
  const pending = connection.call("pending", 1000);
  connection.close();
  await expect(pending).rejects.toThrow("connection closed");
});

test("an unreachable Host reports unavailability, not an unknown submitted outcome", async () => {
  const error = await transport("ws://127.0.0.1:1").call("chats.send", 1000).catch(error => error);
  if (!(error instanceof Error)) throw new Error("Expected a connection error");
  expect(error.message).toContain("Host unavailable");
  expect(error.message).not.toContain("outcome unknown");
});

test("connection loss after submission reports an unknown outcome without retrying", async () => {
  let requests = 0;
  const endpoint = serve((_request, _send, _raw, close) => { requests++; close(); });
  await expect(transport(endpoint).call("chats.send", 1000)).rejects.toThrow("Request outcome unknown");
  expect(requests).toBe(1);
});

const liveEndpoint = process.env.OX_RPC_TEST_ENDPOINT;
test.skipIf(!liveEndpoint)("live Host methods, errors, notifications, batches and rejection of the old protocol", async () => {
  const endpoint = liveEndpoint!;
  const host = client(endpoint);
  await waitForHost(host);
  expect(await host.describe(5000)).toMatchObject({ protocols: description.protocols, methods: expect.arrayContaining(description.methods) });
  const chats = await host.listChats(5000);
  expect((await host.call("vm.inspect", 5000)).value).toBeDefined();
  expect((await host.call("providers.list", 5000)).providers).toBeArray();
  expect((await host.call("logs.list", 5000)).logs).toBeArray();
  expect((await host.call("services.list", 30000)).services).toBeArray();
  await expect(host.call("debug.providers.setKey", 5000)).rejects.toMatchObject({ code: -32602 });
  await expect(host.call("vm.functions", 5000, { function: "ox.missing" })).rejects.toMatchObject({ code: -32000 });
  await expect(host.call("chats.send", 5000, { text: "" })).rejects.toMatchObject({ code: -32000 });
  await expect(host.call("chats.new", 5000, { providerId: "missing" })).rejects.toMatchObject({ code: -32000 });
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
  expect((await exchange(JSON.stringify(Array.from({ length: 65 }, (_, id) => ({
    jsonrpc: "2.0", method: "host.describe", id,
  }))))).error.code).toBe(-32600);
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
  expect(responses[1].result.protocols).toEqual(description.protocols);
  expect(responses[2].error.code).toBe(-32600);
  for (let i = 0; i < 20; i++) socket.send(JSON.stringify({ jsonrpc: "2.0", method: "host.describe" }));
  socket.send(JSON.stringify([{ jsonrpc: "2.0", method: "host.describe" }]));
  const next = await exchange(JSON.stringify({ jsonrpc: "2.0", method: "host.describe", id: "after-notification" }));
  expect(next.id).toBe("after-notification");
}, 60000);

const deniedEndpoints = process.env.OX_RPC_DENIED_ENDPOINTS?.split(",").filter(Boolean);
test.skipIf(!liveEndpoint || !deniedEndpoints?.length)("live Host rejects network paths outside its VPN ingress", async () => {
  await waitForHost(client(liveEndpoint!));
  for (const endpoint of deniedEndpoints!) {
    await expect(client(endpoint).describe(2000)).rejects.toThrow("Host unavailable");
  }
}, 15000);

test.skipIf(!liveEndpoint)("live Host rejects browser-origin WebSocket handshakes", async () => {
  await waitForHost(client(liveEndpoint!));
  // Bun supports handshake headers; this project's DOM declaration omits that overload.
  const Socket = WebSocket as typeof WebSocket & {
    new(url: string, options: { headers: Record<string, string> }): WebSocket;
  };
  const socket = new Socket(liveEndpoint!, { headers: { Origin: "https://untrusted.example" } });
  cleanups.push(() => socket.close());
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("browser-origin rejection timed out")), 3000);
    socket.onopen = () => { clearTimeout(timer); reject(new Error("Host accepted a browser origin")); };
    socket.onerror = () => { clearTimeout(timer); resolve(); };
    socket.onclose = () => { clearTimeout(timer); resolve(); };
  });
});

async function waitForHost(host: HostRPCClient): Promise<void> {
  const deadline = Date.now() + 10_000;
  for (;;) {
    try { await host.describe(500); return; }
    catch (error) { if (Date.now() >= deadline) throw error; }
    await Bun.sleep(100);
  }
}

const lifecycleDevice = process.env.OX_RPC_LIFECYCLE_DEVICE;
test.skipIf(!liveEndpoint || !lifecycleDevice)("foreground lifecycle closes submitted work without replay and permits reconnection", async () => {
  const config = qaConfig(lifecycleDevice!);
  const sim = async (...args: string[]) => {
    const process = Bun.spawn(["sim", "--device", config.device, ...args], { stdout: "ignore", stderr: "pipe" });
    const error = await new Response(process.stderr).text();
    if (await process.exited !== 0) throw new Error(error);
  };
  const host = client(liveEndpoint!);
  await waitForHost(host);
  const chat = await host.call("chats.new", 5000, { temporary: true, providerId: "mock", modelId: "mock" });
  if (typeof chat.chatId !== "string") throw new Error("Expected a temporary QA chat");
  const pending = host.call("chats.send", 30_000, { sessionId: chat.chatId, text: "13" }).catch(error => error);
  try {
    await host.call("chats.get", 5000, { sessionId: chat.chatId });
    await sim("press", "home");
    const error = await pending;
    if (!(error instanceof Error)) throw new Error("Expected connection loss during slow Mock generation");
    expect(error.message).toContain("Request outcome unknown");
    const unavailable = await host.describe(1000).catch(error => error);
    if (!(unavailable instanceof Error)) throw new Error("Expected a background Host to be unavailable");
    expect(unavailable.message).toContain("Host unavailable");
  } finally {
    await sim("run", "ai.oxcraft.bot", "--project", "apps/ios/Ox.xcodeproj", "--scheme", "ios",
      "--env", `OX_HOST_ENDPOINT=${liveEndpoint!}`, "--env", `OX_DEBUG_ENDPOINT=${liveEndpoint!}`);
    await waitForHost(host);
  }
  expect(await host.describe(5000)).toMatchObject({ methods: expect.arrayContaining(description.methods) });
}, 120000);
