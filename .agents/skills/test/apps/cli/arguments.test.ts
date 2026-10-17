import { expect, test } from "bun:test";

const cli = new URL("../../../../../apps/cli/src/ox.ts", import.meta.url).pathname;

async function command(args: string[], entry = cli) {
  const child = Bun.spawn(["bun", entry, ...args], {
    stdout: "pipe", stderr: "pipe", stdin: "ignore",
    env: { ...process.env, OX_REPOSITORY: "", OX_HOST_ENDPOINT: "ws://127.0.0.1:1", OX_QA_DEVICE: "" },
  });
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
  ]);
  return { stdout, stderr, code };
}

test("QA conversation flags and documented runner paths work without a target", async () => {
  for (const name of ["image-embed", "profile-files", "ox-errors", "service-icons", "bundled-skills"]) {
    const entry = new URL(`../ios/${name}.ts`, import.meta.url).pathname;
    for (const flag of ["--conversation", "--chat"]) {
      const args = [`${flag}=saved`, ...(name === "bundled-skills" ? ["--temporary-conversation=temporary"] : [])];
      const help = await command([...args, "--help"], entry);
      expect(help.code).toBe(0);
      expect(help.stdout).toContain("--conversation");
      const missingTarget = await command(args, entry);
      expect(missingTarget.code).toBe(1);
      expect(missingTarget.stderr).toContain("Pass --device");
    }
  }
  const durable = new URL("../ios/durable-conversation.ts", import.meta.url).pathname;
  expect((await command(["--help"], durable)).code).toBe(0);
});

test("CLI help and service argument validation do not connect to a Host", async () => {
  for (const args of [["vm", "inspect"], ["vm", "functions"], ["vm", "help"],
    ["conversation", "open"], ["conversation", "respond"], ["host", "list"], ["host", "discover"], ["host", "service", "refresh-auth"]]) {
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
