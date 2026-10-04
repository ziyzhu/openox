import { afterEach, expect, test } from "bun:test";
import { HostRPCClient } from "../../../apps/cli/src/host-rpc.ts";
import { qaConfig } from "../../../tools/qa/qa-config.ts";

const cleanups: (() => void)[] = [];
afterEach(() => { for (const cleanup of cleanups.splice(0).reverse()) cleanup(); });

function client(endpoint: string): HostRPCClient {
  const value = new HostRPCClient(endpoint);
  cleanups.push(() => value.close());
  return value;
}

const description = {
  implementation: { name: "Ox", version: "1.0.7", build: "1" },
  protocols: { repository: [3] },
  methods: ["host.describe", "chats.list"],
};
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
  expect((await exchange(JSON.stringify({ jsonrpc: "2.0", method: "debug.providers.setKey", params: {}, id: "key-params" }))).error.code).toBe(-32602);
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
  expect(responses[1].result.protocols).toMatchObject(description.protocols);
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
