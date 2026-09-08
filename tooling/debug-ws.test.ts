import { afterEach, expect, test } from "bun:test";
import { DebugConnection, runOnce } from "../apps/cli/src/debug-ws.ts";

const cleanups: (() => void)[] = [];

afterEach(() => {
  for (const cleanup of cleanups.splice(0).reverse()) cleanup();
});

function host(holdHandshake = false) {
  const received = Promise.withResolvers<void>();
  const handshake = Promise.withResolvers<void>();
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request, server) {
      received.resolve();
      if (holdHandshake) await handshake.promise;
      if (server.upgrade(request)) return;
      return new Response("upgrade required", { status: 400 });
    },
    websocket: {
      message(socket, data) {
        const envelope = JSON.parse(String(data));
        if (envelope.kind === "silent") return;
        socket.send("invalid JSON");
        socket.send(JSON.stringify({ id: "unrelated", ok: true }));
        socket.send(JSON.stringify({ id: envelope.id, ok: true, value: envelope.id }));
      },
    },
  });
  const endpoint = `ws://127.0.0.1:${server.port}`;
  const connection = new DebugConnection(endpoint);
  cleanups.push(() => {
    connection.close();
    handshake.resolve();
    void server.stop(true);
  });
  return { connection, endpoint, received: received.promise, handshake };
}

async function promptly<T>(promise: Promise<T>): Promise<T | "still pending"> {
  return Promise.race([promise, Bun.sleep(200).then(() => "still pending" as const)]);
}

test("closing during the handshake settles waiting requests", async () => {
  const { connection, received } = host(true);
  const result = connection.request({ id: "closing" }, 1000);
  await received;
  connection.close();
  expect(await promptly(result)).toEqual({ ok: false, error: "connection closed" });
  expect(await connection.request({ id: "later" }, 1000)).toEqual({ ok: false, error: "connection is closed" });
});

test("concurrent requests have independent deadlines during the handshake", async () => {
  const { connection, received, handshake } = host(true);
  const first = connection.request({ id: "first" }, 1000);
  await received;
  const second = connection.request({ id: "second" }, 30);
  expect(await promptly(second)).toEqual({ ok: false, error: "timeout after 30ms" });
  handshake.resolve();
  expect(await first).toEqual({ id: "first", ok: true, value: "first" });
});

test("concurrent replies match their request and ignore malformed or unrelated messages", async () => {
  const { connection } = host();
  const results = await Promise.all(["one", "two"].map(id => connection.request({ id }, 1000)));
  expect(results).toEqual([
    { id: "one", ok: true, value: "one" },
    { id: "two", ok: true, value: "two" },
  ]);
});

test("duplicate ids cannot overwrite a pending request", async () => {
  const { connection, received, handshake } = host(true);
  const first = connection.request({ id: "same" }, 1000);
  await received;
  expect(await connection.request({ id: "same" }, 30))
    .toEqual({ ok: false, error: "request id is already pending" });
  handshake.resolve();
  expect(await first).toEqual({ id: "same", ok: true, value: "same" });
});

test("a timed out handshake cannot interfere with a replacement connection", async () => {
  const { connection, received, handshake } = host(true);
  const first = connection.request({ id: "expired" }, 30);
  await received;
  expect(await first).toEqual({ ok: false, error: "timeout after 30ms" });
  const next = connection.request({ id: "replacement" }, 1000);
  handshake.resolve();
  expect(await next).toEqual({ id: "replacement", ok: true, value: "replacement" });
});

test("a timed out request does not prevent later requests", async () => {
  const { connection } = host();
  expect(await connection.request({ id: "silent", kind: "silent" }, 30))
    .toEqual({ ok: false, error: "timeout after 30ms" });
  expect(await connection.request({ id: "next" }, 1000)).toEqual({ id: "next", ok: true, value: "next" });
});

test("one-shot requests use the same reply handling", async () => {
  const { endpoint } = host();
  expect(await runOnce({ id: "once" }, 1000, endpoint)).toEqual({ id: "once", ok: true, value: "once" });
});
