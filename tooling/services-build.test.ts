import { afterEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildService, serviceAssetURL } from "../packages/services/src/service.ts";

const roots: string[] = [];

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function source(faviconUrl?: string, withAsset = false): string {
  const root = mkdtempSync(join(tmpdir(), "ox-services-build-"));
  roots.push(root);
  const directory = join(root, "web", "example.com");
  mkdirSync(directory, { recursive: true });
  writeFileSync(join(directory, "service.json"), JSON.stringify({
    domain: "example.com",
    name: "Example",
    baseUrl: "https://example.com/",
    ...(faviconUrl ? { faviconUrl } : {}),
    actions: [{
      id: "read",
      label: "Read",
      inputSchema: { type: "object", properties: {}, required: [], additionalProperties: false },
      outputSchema: { type: "object", properties: {}, required: [], additionalProperties: false },
      requireAuth: false,
      requireApproval: false,
    }],
  }));
  writeFileSync(join(directory, "actions.js"), 'window.ox.install(({ action }) => action("read", { invoke: () => ({}) }));');
  if (withAsset) writeFileSync(join(directory, "favicon.png"), "asset");
  return root;
}

test("a source favicon URL takes precedence over a hosted asset", async () => {
  const url = "https://example.com/icon.png";
  const result = await buildService("example.com", source(url, true));
  expect("error" in result).toBe(false);
  if (!("error" in result)) expect(result.manifest.faviconUrl).toBe(url);
});

test("a service without a source favicon URL uses its hosted asset", async () => {
  const result = await buildService("example.com", source(undefined, true));
  expect("error" in result).toBe(false);
  if (!("error" in result)) expect(result.manifest.faviconUrl).toBe(serviceAssetURL("example.com"));
});

test("an invalid source favicon URL is rejected", async () => {
  const result = await buildService("example.com", source("http://example.com/icon.png"));
  expect("error" in result).toBe(true);
  if ("error" in result) expect(result.error).toContain("faviconUrl");
});
