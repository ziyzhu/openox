import { afterEach, describe, expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildArtifacts } from "./build.ts";
import { SERVICE_ASSET_BASE_URL } from "./service.ts";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(temporaryDirectories.splice(0).map(path => rm(path, { recursive: true, force: true })));
});

describe("buildArtifacts", () => {
  test("publishes stable favicon URLs without packaging image files", async () => {
    const output = await mkdtemp(join(tmpdir(), "ox-services-build-test-"));
    temporaryDirectories.push(output);

    await buildArtifacts(output, { domains: ["github.com"], catalogKinds: [] });

    const service = join(output, "web", "github.com");
    const manifest = JSON.parse(await readFile(join(service, "manifest.json"), "utf8"));
    expect(manifest.faviconUrl).toBe(`${SERVICE_ASSET_BASE_URL}/github.com/favicon.png`);
    expect(existsSync(join(service, "favicon.png"))).toBeFalse();
  });
});
