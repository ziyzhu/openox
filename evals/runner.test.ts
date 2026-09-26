import { expect, test } from "bun:test";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { hash } from "./runner.ts";
import type { Report } from "./types.ts";

test("context hashes ignore JSON object key order", () => {
  expect(hash({ tools: [{ name: "execute", parameters: { b: 2, a: 1 } }] })).toBe(hash({ tools: [{ parameters: { a: 1, b: 2 }, name: "execute" }] }));
});

test("runner writes scored reports over JSON-RPC and compare detects regression", async () => {
  const directory = await mkdtemp(join(tmpdir(), "ox-eval-runner-"));
  let answer = "ready";
  const server = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    fetch(request, server) { if (server.upgrade(request)) return; return new Response("websocket required", { status: 400 }); },
    websocket: {
      message(socket, raw) {
        const request = JSON.parse(String(raw));
        let result: unknown;
        if (request.method === "host.describe") result = { implementation: { name: "fixture", version: "1", build: "1" }, protocols: { host: [1] }, methods: ["agents.evaluate"] };
        else if (request.method === "models.list") result = { region: "global", clients: [{ id: "fixture", models: [{ id: "fixture" }] }] };
        else if (request.method === "chats.get") result = { data: { id: "empty", messages: [] } };
        else if (request.method === "agents.evaluate") {
          expect(request.params.sessionId).toBe("empty");
          expect(request.params.fixtures).toEqual([]);
          result = {
            messages: [{ type: "assistant", assistant: { stopReason: "stop", content: [{ type: "text", text: { text: answer } }] } }],
            errors: [], systemPrompt: "fixture", tools: [], totalMs: 1,
          };
        } else throw new Error(`Unexpected method ${request.method}`);
        socket.send(JSON.stringify({ jsonrpc: "2.0", id: request.id, result }));
      },
    },
  });
  const command = async (args: string[]) => {
    const child = Bun.spawn(["bun", join(import.meta.dir, "runner.ts"), ...args], { stdout: "pipe", stderr: "pipe" });
    const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
    return { code, stdout, stderr };
  };
  const args = ["--host", `ws://127.0.0.1:${server.port}`, "--provider", "fixture", "--model", "fixture", "--case", "brief-answer"];
  const baseline = join(directory, "baseline.json");
  const candidate = join(directory, "candidate.json");
  try {
    const good = await command([...args, "--output", baseline]);
    expect(good.code).toBe(0);
    expect((await stat(baseline)).mode & 0o777).toBe(0o600);
    const report: Report = JSON.parse(await readFile(baseline, "utf8"));
    expect(report.results[0]!.status).toBe("pass");
    answer = "wrong";
    expect((await command([...args, "--output", candidate])).code).toBe(1);
    const diff = await command(["compare", baseline, candidate]);
    expect(diff.code).toBe(1);
    expect(JSON.parse(diff.stdout)[0].change).toBe("regression");
    expect((await command([...args, "--output", baseline])).code).toBe(1);
  } finally {
    server.stop(true);
    await rm(directory, { recursive: true, force: true });
  }
}, 20000);
