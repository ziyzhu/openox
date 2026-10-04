import { strict as assert } from "node:assert";
import { createHash } from "node:crypto";
import { parseArgs } from "node:util";
import { validateParams, validateResult } from "../../packages/protocol/src/index.ts";

const { values } = parseArgs({ options: { host: { type: "string" } } });
const rows = Array.from({ length: 2_807 }, (_, seq) => ({
  seq, time: "2026-10-04T00:00:00.000Z", level: seq % 7 === 0 ? "error" : "info",
  category: seq % 3 === 0 ? "Session" : "Perf", thread: "main", location: "[fixture:1]",
  message: seq === 0 ? "oldest retained failure" : `record ${seq}`,
}));
let legacy = false;
let repeatingCursor = false;
const levels = ["debug", "info", "warning", "error"];
const server = Bun.serve({
  port: 0,
  fetch(request, server) {
    if (server.upgrade(request)) return;
    return new Response("WebSocket required", { status: 400 });
  },
  websocket: {
    message(socket, message) {
      const request = JSON.parse(String(message));
      try {
        assert.equal(request.method, "logs.list");
        assert.ok(validateParams("logs.list", request.params));
        const params = request.params ?? {};
        const signature = createHash("sha256").update(JSON.stringify([params.level, params.category, params.query, params.since])).digest("hex");
        let before = rows.length;
        if (params.cursor && !repeatingCursor) {
          const token = JSON.parse(Buffer.from(params.cursor, "base64").toString());
          assert.equal(token.signature, signature, "cursor filters changed");
          before = token.before;
        }
        const matches = rows.filter(row => row.seq < before
          && (!params.level || levels.indexOf(row.level) >= levels.indexOf(params.level))
          && (!params.category || row.category === params.category)
          && (!params.query || `${row.category} ${row.message}`.toLowerCase().includes(params.query.toLowerCase()))
          && (!params.since || Date.parse(row.time) >= Date.parse(params.since)));
        const logs = matches.slice(-(params.limit ?? 2_000));
        const hasMore = matches.length > logs.length;
        const nextCursor = hasMore ? Buffer.from(JSON.stringify({ before: logs[0]!.seq, signature })).toString("base64") : undefined;
        const result = legacy ? { logs } : { logs, hasMore, nextCursor: repeatingCursor ? "stuck" : nextCursor };
        assert.ok(validateResult("logs.list", result));
        socket.send(JSON.stringify({ jsonrpc: "2.0", id: request.id, result }));
      } catch (error) {
        socket.send(JSON.stringify({ jsonrpc: "2.0", id: request.id, error: { code: -32602, message: String(error) } }));
      }
    },
  },
});

async function cli(host: string, ...args: string[]) {
  const child = Bun.spawn([process.execPath, `${import.meta.dir}/src/ox.ts`, "--host", host, "host", "logs", ...args], { stdout: "pipe", stderr: "pipe" });
  const timer = setTimeout(() => child.kill(), 15_000);
  try {
    const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
    return { stdout, stderr, code };
  } finally { clearTimeout(timer); }
}

async function json(host: string, ...args: string[]): Promise<any> {
  const result = await cli(host, ...args, "--json");
  assert.equal(result.code, 0, result.stderr);
  return JSON.parse(result.stdout);
}

try {
  const host = `ws://127.0.0.1:${server.port}`;
  const first = await json(host, "--page", "--limit", "100");
  assert.equal(first.logs.length, 100);
  assert.equal(first.hasMore, true);
  assert.ok(first.nextCursor);
  rows.push({ ...rows.at(-1)!, seq: rows.length, message: "appended after first page" });
  const second = await json(host, "--cursor", first.nextCursor, "--limit", "200");
  assert.equal(second.logs.length, 200);
  assert.ok(second.logs.at(-1).seq < first.logs[0].seq, "append must not shift an older page");
  const all = await json(host, "--all", "--limit", "137");
  assert.deepEqual(all.map((row: any) => row.seq), rows.map(row => row.seq));
  const tail = await json(host, "--tail", "2500", "--limit", "113");
  assert.deepEqual(tail.map((row: any) => row.seq), rows.slice(-2500).map(row => row.seq));
  const sparse = await json(host, "--grep", "oldest retained", "--category", "Session", "--level", "error", "--since", "2026-10-04T00:00:00Z", "--page", "--limit", "1");
  assert.equal(sparse.logs[0].seq, 0, "server filtering must search beyond the newest 2,000 records");
  assert.equal(sparse.hasMore, false);
  assert.equal(sparse.nextCursor, null);
  assert.equal((await cli(host, "--cursor", first.nextCursor, "--level", "warning")).code, 1);
  assert.equal((await cli(host, "--cursor", "invalid")).code, 1);
  for (const args of [["--limit", "0"], ["--limit", "2001"], ["--limit", "1.5"], ["--all", "--follow"], ["--page", "--tail", "1"]]) {
    assert.equal((await cli(host, ...args)).code, 1, args.join(" "));
  }
  legacy = true;
  assert.ok(Array.isArray(await json(host)), "ordinary reads remain compatible with old Hosts");
  assert.match((await cli(host, "--all")).stderr, /does not support log pagination/);
  legacy = false;
  repeatingCursor = true;
  assert.match((await cli(host, "--all", "--limit", "1")).stderr, /invalid log pagination cursor/);
  console.log("PASS CLI process E2E: older pages, appends, all/tail, sparse server filters, cursor errors, validation, old Hosts");

  const liveHost = values.host ?? Bun.env.OX_RPC_TEST_ENDPOINT;
  if (liveHost) {
    const page = await json(liveHost, "--page", "--limit", "2");
    assert.ok(page.logs.length <= 2);
    assert.equal(typeof page.hasMore, "boolean");
    if (page.hasMore) {
      const older = await json(liveHost, "--cursor", page.nextCursor, "--limit", "3");
      assert.ok(older.logs.length > 0 && older.logs.length <= 3);
      assert.ok(older.logs.at(-1).seq < page.logs[0].seq);
      assert.equal((await cli(liveHost, "--cursor", page.nextCursor, "--level", "error")).code, 1);
    }
    assert.equal((await cli(liveHost, "--cursor", "invalid")).code, 1);
    console.log("PASS live Host log pagination");
  } else console.log("SKIP live Host: pass --host or OX_RPC_TEST_ENDPOINT (iOS requires Tailscale)");
} finally { server.stop(true); }
