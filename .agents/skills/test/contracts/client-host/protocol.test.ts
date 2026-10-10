import { expect, test } from "bun:test";
import { ROOT } from "../../../../lib.ts";
import { hostFixtureReply } from "./fixture.ts";
import { RPC_VERSION } from "../../../../../packages/protocol/src/index.ts";

type FixtureOptions = {
  invalid?: boolean;
  rpcVersions?: number[];
  reconnectRPCVersions?: number[];
  disconnectAfterSnapshot?: boolean;
  descriptionDelayMs?: number;
};

async function exercise(options: FixtureOptions = {}) {
  const requests: string[] = [];
  let connections = 0;
  const server = Bun.serve<{ connection: number }>({
    hostname: "127.0.0.1", port: 0,
    fetch(request, server) {
      if (server.upgrade(request, { data: { connection: ++connections } })) return;
      return new Response("WebSocket required", { status: 400 });
    },
    websocket: {
      message(socket, message) {
        const request = JSON.parse(String(message));
        requests.push(request.method);
        const reply = options.invalid && request.method === "chats.list"
          ? { jsonrpc: "2.0", id: request.id, result: { chats: null } }
          : hostFixtureReply(request);
        if (request.method === "host.describe" && "result" in reply) {
          reply.result = { ...reply.result as Record<string, unknown>, protocols: {
            rpc: socket.data.connection > 1 && options.reconnectRPCVersions !== undefined
              ? options.reconnectRPCVersions : options.rpcVersions ?? [RPC_VERSION],
          } };
        }
        const send = () => {
          socket.send(JSON.stringify(reply));
          if (options.disconnectAfterSnapshot && request.method === "chats.get" && socket.data.connection === 1) socket.close();
        };
        if (request.method === "host.describe" && options.descriptionDelayMs) setTimeout(send, options.descriptionDelayMs);
        else send();
      },
    },
  });
  function start(...args: string[]) {
    return Bun.spawn([process.execPath, `${ROOT}/apps/cli/src/ox.ts`,
      "--host", `ws://127.0.0.1:${server.port}`, ...args, "--json"], {
      env: { ...Bun.env, OX_REPOSITORY: "" }, stdout: "pipe", stderr: "pipe",
    });
  }
  async function cli(...args: string[]) {
    const child = start(...args);
    const [code, stdout, stderr] = await Promise.all([
      child.exited, new Response(child.stdout).text(), new Response(child.stderr).text(),
    ]);
    return { code, stdout, stderr };
  }
  return { cli, start, requests, close: () => server.stop(true) };
}

test("CLI and fixture Host conform across description and chat create/send/inspect", async () => {
  const fixture = await exercise();
  try {
    expect((await fixture.cli("host", "describe")).code).toBe(0);
    const created = await fixture.cli("chat", "new", "--temporary", "--provider", "mock", "--model", "mock");
    expect(created.code).toBe(0);
    const id = JSON.parse(created.stdout).chatId;
    const sent = await fixture.cli("--chat", id, "chat", "send", "hello");
    expect(sent.code).toBe(0);
    expect(JSON.parse(sent.stdout)).toMatchObject({ chatId: id, outcome: "completed", text: "Hello from the fixture." });
    const inspected = await fixture.cli("--chat", id, "chat", "inspect");
    expect(inspected.code).toBe(0);
    expect(JSON.parse(inspected.stdout)).toMatchObject({ id, isBusy: false });
    expect(fixture.requests).toEqual(["host.describe", "host.describe", "chats.new", "host.describe", "chats.send", "host.describe", "chats.get"]);
  } finally { fixture.close(); }
});

test("CLI rejects malformed Host results without retrying a submitted request", async () => {
  const fixture = await exercise({ invalid: true });
  try {
    const result = await fixture.cli("chat", "list");
    expect(result.code).toBe(1);
    expect(result.stderr).toContain("Host returned an invalid chat list");
    expect(fixture.requests).toEqual(["host.describe", "chats.list"]);
  } finally { fixture.close(); }
});

test("CLI rejects unsupported and unversioned RPC interfaces before mutation while allowing discovery", async () => {
  for (const rpcVersions of [[RPC_VERSION + 1], []]) {
    const fixture = await exercise({ rpcVersions });
    try {
      const description = await fixture.cli("host", "describe");
      expect(description.code).toBe(0);
      expect(JSON.parse(description.stdout).protocols.rpc).toEqual(rpcVersions);
      const result = await fixture.cli("chat", "new", "--temporary");
      expect(result.code).toBe(1);
      expect(result.stderr).toContain(`do not support CLI revision ${RPC_VERSION}`);
      expect(result.stderr).toContain("Operation request not sent");
      expect(fixture.requests).toEqual(["host.describe", "host.describe"]);
    } finally { fixture.close(); }
  }
});

test("CLI accepts the current RPC revision when the Host also supports newer revisions", async () => {
  const fixture = await exercise({ rpcVersions: [RPC_VERSION, RPC_VERSION + 1] });
  try {
    expect((await fixture.cli("chat", "new", "--temporary")).code).toBe(0);
    expect(fixture.requests).toEqual(["host.describe", "chats.new"]);
  } finally { fixture.close(); }
});

test("CLI spends the operation timeout on admission without sending the mutation", async () => {
  const fixture = await exercise({ descriptionDelayMs: 100 });
  try {
    const result = await fixture.cli("chat", "new", "--temporary", "--timeout", "20");
    expect(result.code).toBe(1);
    expect(result.stderr).toContain("timeout");
    expect(fixture.requests).toEqual(["host.describe"]);
  } finally { fixture.close(); }
});

async function watchRequests(options: FixtureOptions, ready: (requests: string[]) => boolean) {
  const fixture = await exercise(options);
  const child = fixture.start("chat", "watch", "--interval", "10");
  const stdout = new Response(child.stdout).text();
  const stderr = new Response(child.stderr).text();
  try {
    const deadline = Date.now() + 3000;
    while (!ready(fixture.requests) && Date.now() < deadline) await Bun.sleep(10);
    expect(ready(fixture.requests)).toBe(true);
    await Bun.sleep(30);
  } finally {
    child.kill("SIGINT");
    await child.exited;
    fixture.close();
  }
  return { requests: fixture.requests, stdout: await stdout, stderr: await stderr };
}

test("CLI admits the interface once for repeated requests on one connection", async () => {
  const result = await watchRequests({}, requests => requests.filter(method => method === "chats.get").length >= 3);
  expect(result.requests.filter(method => method === "host.describe")).toEqual(["host.describe"]);
  expect(result.stderr).toBe("");
});

test("CLI rechecks the interface after reconnecting", async () => {
  const result = await watchRequests({ disconnectAfterSnapshot: true }, requests => requests.filter(method => method === "chats.get").length >= 2);
  expect(result.requests.slice(0, 4)).toEqual(["host.describe", "chats.get", "host.describe", "chats.get"]);
});

test("CLI refuses ordinary requests after reconnecting to an incompatible Host", async () => {
  const result = await watchRequests({ disconnectAfterSnapshot: true, reconnectRPCVersions: [RPC_VERSION + 1] },
    requests => requests.filter(method => method === "host.describe").length >= 2);
  expect(result.requests).toEqual(["host.describe", "chats.get", "host.describe"]);
  expect(result.stderr).toContain(`do not support CLI revision ${RPC_VERSION}`);
});

test("CLI reports Host errors without replaying mutations", async () => {
  const fixture = await exercise();
  try {
    const result = await fixture.cli("chat", "new", "--provider", "missing", "--model", "missing");
    expect(result.code).toBe(1);
    expect(result.stderr).toContain("fixture rejected provider");
    expect(fixture.requests).toEqual(["host.describe", "chats.new"]);
  } finally { fixture.close(); }
});
