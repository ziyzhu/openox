import { expect, test } from "bun:test";
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { ROOT } from "../../../../lib.ts";

test("A clean checkout builds complete agent resources and rejects incomplete ones", async () => {
  const directory = await mkdtemp(join(tmpdir(), "openox-agent-packaging-"));
  const ios = join(directory, "apps/ios");
  const bundle = join(directory, "apps/shared/Resources/PiDurable.bundle");
  const environment = { ...Bun.env, SRCROOT: ios,
    BUN_INSTALL_CACHE_DIR: Bun.env.BUN_INSTALL_CACHE_DIR ?? join(Bun.env.BUN_INSTALL ?? join(homedir(), ".bun"), "install/cache") };
  async function shell(script: string) {
    return await spawn(["sh", join(ios, script)], tmpdir());
  }
  async function spawn(command: string[], cwd: string) {
    const child = Bun.spawn(command, {
      cwd, env: environment, stdout: "pipe", stderr: "pipe",
    });
    const [code, stdout, stderr] = await Promise.all([
      child.exited, new Response(child.stdout).text(), new Response(child.stderr).text(),
    ]);
    return { code, output: stdout + stderr };
  }
  try {
    const files = Bun.spawnSync(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z",
      "--", "package.json", "bun.lock", "packages", "apps/cli/package.json", "apps/ios", "apps/shared"], { cwd: ROOT });
    expect(files.exitCode).toBe(0);
    for (const path of files.stdout.toString().split("\0").filter(Boolean)) {
      if (!await Bun.file(join(ROOT, path)).exists()) continue;
      await mkdir(dirname(join(directory, path)), { recursive: true });
      await copyFile(join(ROOT, path), join(directory, path));
    }
    expect(await Bun.file(join(bundle, "harness.js")).exists()).toBe(false);
    const missing = await shell("../shared/validate-agent-bundle.sh");
    expect(missing.code, missing.output).toBe(1);
    expect(missing.output).toContain("bun run build:agent");
    for (const command of [["install", "--frozen-lockfile"], ["run", "build:agent"]]) {
      const prepared = await spawn([process.execPath, "--no-env-file", ...command], directory);
      expect(prepared.code, prepared.output).toBe(0);
    }
    const complete = await shell("../shared/validate-agent-bundle.sh");
    expect(complete.code, complete.output).toBe(0);
    const manifest = await Bun.file(join(bundle, "manifest.json")).json();
    for (const [name, metadata] of Object.entries({ ...manifest.bundles, ...manifest.resources })) {
      const contents = await readFile(join(bundle, name));
      expect(metadata).toEqual({ bytes: contents.length, sha256: new Bun.CryptoHasher("sha256").update(contents).digest("hex") });
      await writeFile(join(bundle, name), "");
      const incomplete = await shell("../shared/validate-agent-bundle.sh");
      expect(incomplete.code, incomplete.output).toBe(1);
      expect(incomplete.output).toContain(name);
      await writeFile(join(bundle, name), contents);
    }
  } finally { await rm(directory, { recursive: true, force: true }); }
}, 120_000);
