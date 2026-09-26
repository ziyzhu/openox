import { expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

test.skipIf(process.platform !== "darwin")("secret listing exposes only metadata and sanitizes invalid JSON errors", async () => {
  const directory = await mkdtemp(join(tmpdir(), "ox-secret-metadata-"));
  try {
    const executable = join(directory, "secret-metadata-tests");
    const compiler = Bun.spawn(["xcrun", "swiftc", "-module-cache-path", join(directory, "cache"),
      "apps/ios/Ox/Platform/Models/JSONValue.swift",
      "apps/ios/Ox/Host/Chats/Functions/SecretFunctions.swift",
      "tooling/fixtures/secret-metadata.swift", "-o", executable], { stdout: "pipe", stderr: "pipe" });
    const diagnostics = await new Response(compiler.stderr).text();
    expect(await compiler.exited, diagnostics).toBe(0);
    const run = Bun.spawn([executable], { stdout: "pipe", stderr: "pipe" });
    const errors = await new Response(run.stderr).text();
    expect(await run.exited, errors).toBe(0);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}, 60_000);
