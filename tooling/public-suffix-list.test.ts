import { expect, test } from "bun:test";
import { cp, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

test.skipIf(process.platform !== "darwin")("bundled public suffix rules preserve website boundaries", async () => {
  const directory = await mkdtemp(join(tmpdir(), "ox-public-suffix-list-"));
  try {
    await cp("apps/ios/Ox/Resources/PublicSuffixList.bundle", join(directory, "PublicSuffixList.bundle"), { recursive: true });
    const executable = join(directory, "public-suffix-list-tests");
    const compiler = Bun.spawn(["xcrun", "swiftc", "-module-cache-path", join(directory, "cache"),
      "apps/ios/Ox/Host/Services/Web/WebsitePublicSuffixList.swift",
      "tooling/fixtures/public-suffix-list.swift", "-o", executable], { stdout: "pipe", stderr: "pipe" });
    const diagnostics = await new Response(compiler.stderr).text();
    expect(await compiler.exited, diagnostics).toBe(0);
    const run = Bun.spawn([executable], { stdout: "pipe", stderr: "pipe" });
    const errors = await new Response(run.stderr).text();
    expect(await run.exited, errors).toBe(0);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}, 60_000);
