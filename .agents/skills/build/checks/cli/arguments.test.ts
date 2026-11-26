import { expect, test } from "bun:test";

const cli = new URL("../../../../../apps/cli/src/ox.ts", import.meta.url).pathname;

async function command(args: string[]) {
  const child = Bun.spawn(["bun", cli, ...args], {
    stdout: "pipe", stderr: "pipe", stdin: "ignore",
    env: { ...process.env, OX_REPOSITORY: "", OX_PROFILE_ENDPOINT: "ws://127.0.0.1:1", OX_QA_DEVICE: "" },
  });
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
  ]);
  return { stdout, stderr, code };
}

test("CLI help and service argument validation do not connect to a Profile", async () => {
  for (const args of [["vm", "inspect"], ["vm", "functions"], ["vm", "help"],
    ["conversation", "open"], ["conversation", "respond"], ["profile", "discover"], ["profile", "describe"], ["host", "list"], ["service", "refresh-auth"],
    ["service", "list"], ["service", "mcp"], ["files", "mount"], ["files", "list"],
    ["repository", "connect"], ["repository", "list"], ["repository", "disconnect"]]) {
    const result = await command([...args, "--help"]);
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Usage:");
    if (args[1] === "discover" || args[0] === "host") expect(result.stdout).toContain("Usage: ox profile discover");
  }
  for (const args of [["service", "list", "--typo"], ["service", "reload", "example.com", "extra"],
    ["service", "invoke", "example.com:read", "--args", "{}", "--args-file", "-"],
    ["vm", "inspect", "--timeout", "invalid"]]) {
    const result = await command(args);
    expect(result.code).toBe(1);
    expect(result.stderr).not.toContain("Ox connection failed");
  }
});
