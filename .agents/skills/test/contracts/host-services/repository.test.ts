import { expect, test } from "bun:test";
import { cp, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ROOT } from "../../../../lib.ts";

async function ox(repository: string, ...args: string[]) {
  const process = Bun.spawn(["bun", join(ROOT, "apps/cli/src/ox.ts"), "--repository", repository, "repository", ...args], {
    cwd: ROOT, stdout: "pipe", stderr: "pipe",
  });
  const [code, stdout, stderr] = await Promise.all([
    process.exited, new Response(process.stdout).text(), new Response(process.stderr).text(),
  ]);
  return { code, stdout, stderr };
}

// Exercise the real CLI, repository loader, SDK compatibility exports, shared
// validators, and installer inspection; no fake Host or schema-only unit tests.
for (const repository of ["repositories/builtin", "examples/repository"]) {
  test(`CLI validates existing ${repository} through shared repository contracts`, async () => {
    const result = await ox(join(ROOT, repository), "validate");
    expect(result.code).toBe(0);
    expect(result.stderr).toBe("");
  }, 30000);
}

test("CLI rejects an unsupported repository version without modifying its files", async () => {
  const root = await mkdtemp(join(tmpdir(), "ox-repository-contract-future-"));
  const path = join(root, "repository.json");
  const contents = JSON.stringify({ version: 999, name: "Future", services: [], skills: [] });
  try {
    await writeFile(path, contents);
    const result = await ox(root, "validate");
    expect(result.code).not.toBe(0);
    expect(result.stderr).toContain("invalid repository.json");
    expect(await readFile(path, "utf8")).toBe(contents);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("CLI rejects mismatched action registration without changing repository contents", async () => {
  const root = await mkdtemp(join(tmpdir(), "ox-repository-contract-installer-"));
  try {
    await cp(join(ROOT, "examples/repository"), root, { recursive: true });
    const path = join(root, "web/example.com/actions.js");
    const contents = 'window.ox.install(({action}) => action("undeclared", {invoke() {return {}}}));';
    await writeFile(path, contents);
    const result = await ox(root, "validate");
    expect(result.code).not.toBe(0);
    expect(result.stderr).toContain("action registration mismatch");
    expect(await readFile(path, "utf8")).toBe(contents);
  } finally { await rm(root, { recursive: true, force: true }); }
});
