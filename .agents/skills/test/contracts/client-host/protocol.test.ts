import { expect, test } from "bun:test";
import { ROOT } from "../../../../lib.ts";
import { hostFixtureReply } from "./fixture.ts";

async function exercise(invalid = false) {
  const requests: string[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    fetch(request, server) {
      if (server.upgrade(request)) return;
      return new Response("WebSocket required", { status: 400 });
    },
    websocket: {
      message(socket, message) {
        const request = JSON.parse(String(message));
        requests.push(request.method);
        socket.send(JSON.stringify(invalid
          ? { jsonrpc: "2.0", id: request.id, result: { chats: null } }
          : hostFixtureReply(request)));
      },
    },
  });
  async function cli(...args: string[]) {
    const child = Bun.spawn([process.execPath, `${ROOT}/apps/cli/src/ox.ts`,
      "--host", `ws://127.0.0.1:${server.port}`, ...args, "--json"], {
      env: { ...Bun.env, OX_REPOSITORY: "" }, stdout: "pipe", stderr: "pipe",
    });
    const [code, stdout, stderr] = await Promise.all([
      child.exited, new Response(child.stdout).text(), new Response(child.stderr).text(),
    ]);
    return { code, stdout, stderr };
  }
  return { cli, requests, close: () => server.stop(true) };
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
    expect(fixture.requests).toEqual(["host.describe", "chats.new", "chats.send", "chats.get"]);
  } finally { fixture.close(); }
});

test("CLI rejects malformed Host results without retrying a submitted request", async () => {
  const fixture = await exercise(true);
  try {
    const result = await fixture.cli("chat", "list");
    expect(result.code).toBe(1);
    expect(result.stderr).toContain("Host returned an invalid chat list");
    expect(fixture.requests).toEqual(["chats.list"]);
  } finally { fixture.close(); }
});

test("CLI reports Host errors without replaying mutations", async () => {
  const fixture = await exercise();
  try {
    const result = await fixture.cli("chat", "new", "--provider", "missing", "--model", "missing");
    expect(result.code).toBe(1);
    expect(result.stderr).toContain("fixture rejected provider");
    expect(fixture.requests).toEqual(["chats.new"]);
  } finally { fixture.close(); }
});
