import { afterEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { validateServiceManifest } from "../packages/service-sdk/src/manifest.ts";
import { readRepository } from "../apps/cli/src/repositories.ts";

const roots: string[] = [];
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });

const manifest = {
  domain: "example.com",
  name: "Example",
  baseUrl: "https://example.com/",
  faviconUrl: "https://example.com/favicon.png",
  actions: [{
    id: "read",
    label: "Read",
    inputSchema: { type: "object", properties: { url: { type: "string", format: "uri" } }, additionalProperties: false },
    outputSchema: { type: "object", properties: {}, additionalProperties: false },
    requireApproval: false,
    requireAuth: false,
  }],
};

function repository(actions: string, service: Record<string, unknown> = manifest): string {
  const root = mkdtempSync(join(tmpdir(), "ox-repository-validate-"));
  roots.push(root);
  mkdirSync(join(root, "web", "example.com"), { recursive: true });
  writeFileSync(join(root, "repository.json"), JSON.stringify({ version: 2, name: "Example", services: ["web:example.com"] }));
  writeFileSync(join(root, "web", "example.com", "service.json"), JSON.stringify(service));
  writeFileSync(join(root, "web", "example.com", "actions.js"), actions);
  return root;
}

test("a service with Host-accepted fields and a matching installer is valid", async () => {
  const root = repository('window.ox.install(({ action }) => action("read", { invoke: () => ({}) }));');
  expect((await readRepository(root)).services).toEqual(["web:example.com"]);
});

test.each([
  ['window.ox.install(2, ({ action }) => action("read", { invoke: () => ({}) }));', "window.ox.install takes only the installer"],
  ['window.ox.install(({ action, retryFetch }) => { retryFetch; action("read", { invoke: () => ({}) }); });', "service installer does not provide retryFetch"],
  ['window.ox.install(({ action }) => action("other", { invoke: () => ({}) }));', "missing implementations: read; undeclared implementations: other"],
])("invalid installers are reported per service: %s", async (actions, message) => {
  await expect(readRepository(repository(actions))).rejects.toThrow(`web:example.com: `);
  await expect(readRepository(repository(actions))).rejects.toThrow(message);
});

test("manifest errors are reported before running the installer", async () => {
  const root = repository('window.ox.install(({ action }) => action("read", { invoke: () => ({}) }));', { ...manifest, domain: "other.com", baseUrl: "https://other.com/" });
  await expect(readRepository(root)).rejects.toThrow('service.json domain "other.com" does not match example.com');
});

test("the built-in profile keeps its stricter manifest rules", () => {
  const builtin = validateServiceManifest(manifest);
  expect(builtin.ok).toBe(false);
  if (!builtin.ok) expect(builtin.errors.join("\n")).toContain("faviconUrl");
  expect(validateServiceManifest(manifest, "repository").ok).toBe(true);
});
