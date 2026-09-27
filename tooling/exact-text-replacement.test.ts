import { expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

test.skipIf(process.platform !== "darwin")("exact text edits preserve line endings and report failing edits", async () => {
  const directory = await mkdtemp(join(tmpdir(), "ox-exact-text-replacement-"));
  try {
    const executable = join(directory, "exact-text-replacement-tests");
    const compiler = Bun.spawn(["xcrun", "swiftc", "-module-cache-path", join(directory, "cache"),
      "apps/ios/Ox/Platform/Models/ExactTextReplacement.swift",
      "tooling/fixtures/exact-text-replacement.swift", "-o", executable], { stdout: "pipe", stderr: "pipe" });
    const diagnostics = await new Response(compiler.stderr).text();
    expect(await compiler.exited, diagnostics).toBe(0);
    const run = Bun.spawn([executable], { stdout: "pipe", stderr: "pipe" });
    const errors = await new Response(run.stderr).text();
    expect(await run.exited, errors).toBe(0);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}, 60_000);
