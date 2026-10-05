import { expect, test } from "bun:test";
import { cp, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
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

for (const repository of ["apps/ios/Ox/Resources/OxServices.bundle", "examples/repository"]) {
  test(`CLI validates existing ${repository} through shared repository contracts`, async () => {
    const result = await ox(join(ROOT, repository), "validate");
    expect(result.code).toBe(0);
    expect(result.stderr).toBe("");
  }, 30000);
}

test("CLI loads third-party skill resources and rejects symbolic links without modifying contents", async () => {
  const root = await mkdtemp(join(tmpdir(), "ox-repository-contract-skills-"));
  const directory = join(root, "skills", "example-workflow");
  const instructions = "---\nname: example-workflow\ndescription: Example workflow\n---\nUse the example service.";
  try {
    await mkdir(join(directory, "references"), { recursive: true });
    await writeFile(join(root, "repository.json"), JSON.stringify({ version: 3, name: "Example", services: [], skills: ["example-workflow"] }));
    await writeFile(join(directory, "SKILL.md"), instructions);
    await writeFile(join(directory, "references", "guide.md"), "Example reference");
    const valid = await ox(root, "validate");
    expect(valid.code).toBe(0);
    expect(valid.stderr).toBe("");
    expect(valid.stdout).toContain("skills=1");
    await symlink(join(directory, "SKILL.md"), join(directory, "references", "linked.md"));
    const invalid = await ox(root, "validate");
    expect(invalid.code).not.toBe(0);
    expect(invalid.stderr).toContain("symbolic links are unsupported");
    expect(await readFile(join(directory, "SKILL.md"), "utf8")).toBe(instructions);
  } finally { await rm(root, { recursive: true, force: true }); }
});

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
