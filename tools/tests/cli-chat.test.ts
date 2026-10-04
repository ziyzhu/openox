import { expect, test } from "bun:test";
import { qaConfig } from "../qa-config.ts";

type PendingPrompt = { id: string; options: string[] };
type Snapshot = { id: string; isBusy: boolean; pendingPrompt?: PendingPrompt | null; blocks?: unknown[] };
const device = process.env.OX_CLI_TEST_DEVICE;
const config = device ? qaConfig(device) : undefined;
const cli = new URL("../../apps/cli/src/ox.ts", import.meta.url).pathname;

async function command(args: string[], stdin?: string) {
  const child = Bun.spawn(["bun", cli, ...(config ? ["--host", config.debugEndpoint] : []), ...args], {
    stdout: "pipe", stderr: "pipe", stdin: stdin === undefined ? "ignore" : "pipe",
    env: { ...process.env, OX_REPOSITORY: "", OX_HOST_ENDPOINT: config?.debugEndpoint ?? "ws://127.0.0.1:1" },
  });
  if (stdin !== undefined && typeof child.stdin !== "number") {
    child.stdin?.write(stdin);
    child.stdin?.end();
  }
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
  ]);
  return { stdout, stderr, code };
}

async function json<T>(args: string[]): Promise<T> {
  const result = await command([...args, "--json"]);
  if (result.code !== 0) throw new Error(result.stderr);
  return JSON.parse(result.stdout) as T;
}

// Invokes real CLI processes. Help and argument rejection must work without a Host.
test("CLI help and service argument validation do not connect to a Host", async () => {
  for (const args of [["vm", "inspect"], ["vm", "functions"], ["vm", "help"],
    ["chat", "open"], ["chat", "respond"], ["host", "service", "refresh-auth"]]) {
    const result = await command([...args, "--help"]);
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Usage:");
  }
  for (const args of [["host", "services", "--typo"], ["host", "service", "reload", "example.com", "extra"],
    ["host", "service", "invoke", "example.com:read", "--args", "{}", "--args-file", "-"],
    ["vm", "inspect", "--timeout", "invalid"]]) {
    const result = await command(args);
    expect(result.code).toBe(1);
    expect(result.stderr).not.toContain("Host unavailable");
  }
});

// Only run on an explicitly owned numbered QA simulator; never on a personal phone.
test.skipIf(!config)("CLI loads evicted saved chats and resolves current choices without replaying stale responses", async () => {
  const original = await json<Array<{ id: string; active: boolean }>>(["chat", "list", "--active"]);
  const created: string[] = [];
  const prefix = `CLI QA ${Date.now()}`;
  try {
    // Six persisted chats exceed the Host's five-chat hydration cache.
    for (let index = 0; index < 6; index++) {
      const chat = await json<{ chatId: string }>(["chat", "new", "--provider", "mock", "--model", "mock"]);
      created.push(chat.chatId);
      await json(["--chat", chat.chatId, "chat", "send", "0"]);
      await json(["--chat", chat.chatId, "vm", "call", "ox.app.renameChat", "--args",
        JSON.stringify({ title: `${prefix} ${index}`, purpose: "Name CLI QA chat" })]);
    }
    const matches = await json<Array<{ id: string }>>(["chat", "list", "--search", prefix, "--limit", "2"]);
    expect(matches).toHaveLength(2);
    let unloaded = await command(["--chat", created[0]!, "chat", "inspect", "--pending"]);
    for (let attempt = 0; unloaded.code === 0 && attempt < 30; attempt++) {
      await Bun.sleep(100);
      unloaded = await command(["--chat", created[0]!, "chat", "inspect", "--pending"]);
    }
    expect(unloaded.stderr).toContain("unknown chat");
    const opened = await json<Snapshot>(["--chat", created[0]!, "chat", "open"]);
    expect(opened.id).toBe(created[0]!);
    expect((await json<Snapshot>(["--chat", created[0]!, "chat", "inspect", "--pending"])).id).toBe(created[0]!);

    const chat = await json<{ chatId: string }>(["chat", "new", "--temporary", "--provider", "mock", "--model", "mock"]);
    const send = await command(["--chat", chat.chatId, "chat", "send", "25", "--json"]);
    expect(send.code).toBe(1);
    expect(JSON.parse(send.stdout).outcome).toBe("needsAttention");
    const pending = await json<Snapshot>(["--chat", chat.chatId, "chat", "inspect", "--pending"]);
    const prompt = pending.pendingPrompt!;
    expect(prompt.options).toContain("Pro");
    const stale = await command(["--chat", chat.chatId, "chat", "respond", "Pro", "--prompt", crypto.randomUUID()]);
    expect(stale.code).toBe(1);
    expect((await json<Snapshot>(["--chat", chat.chatId, "chat", "inspect", "--pending"])).pendingPrompt?.id).toBe(prompt.id);
    const response = await command(["--chat", chat.chatId, "chat", "respond", "-", "--prompt", prompt.id], "Pro\n");
    expect(response.code).toBe(0);
    expect((await command(["--chat", chat.chatId, "chat", "respond", "Pro", "--prompt", prompt.id])).code).toBe(1);
    let completed: Snapshot | undefined;
    for (let attempt = 0; attempt < 40; attempt++) {
      completed = await json<Snapshot>(["--chat", chat.chatId, "chat", "inspect", "--blocks", "--pending"]);
      if (!completed.isBusy) break;
      await Bun.sleep(100);
    }
    expect(completed?.isBusy).toBe(false);
    expect(JSON.stringify(completed?.blocks)).toContain("Pro");
  } finally {
    if (original[0]) await command(["--chat", original[0].id, "chat", "open"]);
    // Persisted QA chats are intentionally retained for inspection on the test simulator.
    console.log(`CLI QA chats: ${created.join(", ")}`);
  }
}, 120000);
