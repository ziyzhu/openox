import { expect, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ROOT } from "../../../../lib.ts";
import { validateParams, validateResult } from "../../../../../packages/protocol/src/index.ts";
import { hostFixtureReply } from "./fixture.ts";

test("CLI and Host contract preserve independent session and pageUrl routing", async () => {
  const requests: Record<string, unknown>[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    fetch(request, server) {
      if (server.upgrade(request)) return;
      return new Response("WebSocket required", { status: 400 });
    },
    websocket: {
      message(socket, message) {
        const request = JSON.parse(String(message));
        if (request.method !== "services.invoke") {
          socket.send(JSON.stringify(hostFixtureReply(request)));
          return;
        }
        requests.push(request.params);
        expect(validateParams(request.method, request.params)).toBe(true);
        const result = { value: request.params };
        expect(validateResult(request.method, result)).toBe(true);
        socket.send(JSON.stringify({ jsonrpc: "2.0", id: request.id, result }));
      },
    },
  });
  const directory = await mkdtemp(join(tmpdir(), "ox-routing-protocol-"));
  async function cli(...args: string[]) {
    const child = Bun.spawn([process.execPath, `${ROOT}/apps/cli/src/ox.ts`,
      "--host", `ws://127.0.0.1:${server.port}`, "service", "invoke", "example.org:read", ...args, "--json"], {
      env: { ...Bun.env, OX_REPOSITORY: "" }, stdout: "pipe", stderr: "pipe",
    });
    const [code, stdout, stderr] = await Promise.all([
      child.exited, new Response(child.stdout).text(), new Response(child.stderr).text(),
    ]);
    return { code, stdout, stderr };
  }
  try {
    const session = { id: "fixture-account", label: "Fixture account", url: "https://example.org/account" };
    const pageUrl = "https://example.org/resource";
    const file = join(directory, "session.json");
    await writeFile(file, JSON.stringify(session));
    for (const selection of [["--session", JSON.stringify(session)], ["--session-file", file]]) {
      const result = await cli(...selection, "--page-url", pageUrl);
      expect(result.code).toBe(0);
      expect(JSON.parse(result.stdout)).toMatchObject({ session, pageUrl });
    }
    const defaulted = await cli("--page-url", pageUrl);
    expect(defaulted.code).toBe(0);
    expect(JSON.parse(defaulted.stdout)).toMatchObject({ pageUrl });
    expect(JSON.parse(defaulted.stdout)).not.toHaveProperty("session");
    const conflicting = await cli("--session", JSON.stringify(session), "--session-file", file, "--page-url", pageUrl);
    expect(conflicting.code).toBe(1);
    expect(conflicting.stderr).toContain("use either --session or --session-file");
    const invalidTarget = await cli("--session", JSON.stringify(session), "--page-url", "https://user:password@example.org/");
    expect(invalidTarget.code).toBe(1);
    expect(requests).toHaveLength(3);
  } finally {
    server.stop(true);
    await rm(directory, { recursive: true, force: true });
  }
});
