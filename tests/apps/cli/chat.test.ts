import { expect, test } from "bun:test";

const cli = new URL("../../../apps/cli/src/ox.ts", import.meta.url).pathname;

async function command(args: string[]) {
  const child = Bun.spawn(["bun", cli, ...args], {
    stdout: "pipe", stderr: "pipe", stdin: "ignore",
    env: { ...process.env, OX_REPOSITORY: "", OX_HOST_ENDPOINT: "ws://127.0.0.1:1", OX_QA_DEVICE: "" },
  });
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
  ]);
  return { stdout, stderr, code };
}

// Invokes real CLI processes. Help and argument rejection must work without a Host.
test("CLI help and service argument validation do not connect to a Host", async () => {
  for (const args of [["vm", "inspect"], ["vm", "functions"], ["vm", "help"],
    ["chat", "open"], ["chat", "respond"], ["host", "list"], ["host", "discover"], ["host", "service", "refresh-auth"]]) {
    const result = await command([...args, "--help"]);
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Usage:");
    if (args[0] === "host" && ["list", "discover"].includes(args[1]!)) expect(result.stdout).toContain("Usage: ox host list");
  }
  for (const args of [["host", "services", "--typo"], ["host", "service", "reload", "example.com", "extra"],
    ["host", "service", "invoke", "example.com:read", "--args", "{}", "--args-file", "-"],
    ["vm", "inspect", "--timeout", "invalid"]]) {
    const result = await command(args);
    expect(result.code).toBe(1);
    expect(result.stderr).not.toContain("Host unavailable");
  }
});
