import { expect, test } from "bun:test";
import { join } from "node:path";
import { ROOT } from "../../../../lib.ts";
import { contracts } from "../../../../../packages/agent/src/functions/contracts.ts";

async function command(args: string[]) {
  const child = Bun.spawn([process.execPath, "--no-env-file", join(ROOT, ".agents/skills/evals/scripts/runner.ts"), ...args], { cwd: ROOT, stdout: "pipe", stderr: "pipe", stdin: "ignore" });
  const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
  return { code, stdout, stderr };
}

test("eval CLI validates code-defined cases against the native function catalog", async () => {
  const result = await command(["--validate"]);
  expect(result.code, result.stderr).toBe(0);
  expect(result.stdout).toContain(`stub catalog matches ${Object.keys(contracts).length} native functions`);
  const listed = await command(["--list"]);
  expect(listed.stdout.trim().split("\n")).toContain("app-profile");
  const help = await command(["--help"]);
  expect(help.stdout).not.toContain("--host");
  expect(help.stdout).toContain("No Host or simulator");
});

test("eval CLI rejects runs without a model, unknown cases, unknown baselines and in-repository reports", async () => {
  expect((await command([])).code).toBe(1);
  expect((await command(["--provider", "openai", "--model", "m", "--case", "missing"])).stderr).toContain("Unknown case");
  expect((await command(["--provider", "openai", "--model", "m", "--output", join(ROOT, "eval-output")])).stderr).toContain("outside the repository");
  expect((await command(["--provider", "openai", "--model", "m", "--baseline", "no-such-ref"])).stderr).toContain("rev-parse");
});
