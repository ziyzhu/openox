import { afterEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { validateServiceManifest } from "../../packages/service-sdk/src/manifest.ts";
import { readRepository } from "../../apps/cli/src/repositories.ts";

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
  writeFileSync(join(root, "repository.json"), JSON.stringify({ version: 3, name: "Example", services: ["web:example.com"], skills: [] }));
  writeFileSync(join(root, "web", "example.com", "service.json"), JSON.stringify(service));
  writeFileSync(join(root, "web", "example.com", "actions.js"), actions);
  return root;
}

test("a service with Host-accepted fields and a matching installer is valid", async () => {
  const root = repository('window.ox.install(({ action }) => action("read", { invoke: () => ({}) }));');
  expect((await readRepository(root)).services).toEqual(["web:example.com"]);
});

test("action mismatches are reported per service", async () => {
  const root = repository('window.ox.install(({ action }) => action("other", { invoke: () => ({}) }));');
  await expect(readRepository(root)).rejects.toThrow("web:example.com: action registration mismatch; missing implementations: read; undeclared implementations: other");
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

function skillRepository(names: string[] = ["research"]): string {
  const root = mkdtempSync(join(tmpdir(), "ox-skills-validate-"));
  roots.push(root);
  writeFileSync(join(root, "repository.json"), JSON.stringify({ version: 3, name: "Skills", services: [], skills: names }));
  for (const name of names) {
    const directory = join(root, "skills", name);
    mkdirSync(join(directory, "scripts"), { recursive: true });
    mkdirSync(join(directory, "references", "nested"), { recursive: true });
    writeFileSync(join(directory, "SKILL.md"), `---\nname: ${name}\ndescription: Research a topic\nservices: example.com\n---\nRead references/nested/guide.md.\n`);
    writeFileSync(join(directory, "scripts", "run.js"), 'return await ox.fs.read({ path: "memory.md", purpose: "Read context" });');
    writeFileSync(join(directory, "references", "nested", "guide.md"), "Research carefully.");
  }
  return root;
}

test("a skill-only repository validates complete packages", async () => {
  expect((await readRepository(skillRepository())).skills).toEqual(["research"]);
});

test("repositories reject reserved and duplicate skill names", async () => {
  await expect(readRepository(skillRepository(["manage-skills"]))).rejects.toThrow();
  await expect(readRepository(skillRepository(["import-memory"]))).rejects.toThrow();
  await expect(readRepository(skillRepository(["research", "research"]))).rejects.toThrow();
});

test("repositories reject missing skills and unsupported scripts", async () => {
  const root = skillRepository();
  writeFileSync(join(root, "skills", "research", "scripts", "run.py"), "print('no')");
  await expect(readRepository(root)).rejects.toThrow("invalid file");
  rmSync(join(root, "skills", "research"), { recursive: true });
  await expect(readRepository(root)).rejects.toThrow();
});

test("repository skills reject symbolic resources", async () => {
  const root = skillRepository();
  symlinkSync(join(root, "repository.json"), join(root, "skills", "research", "references", "link.md"));
  await expect(readRepository(root)).rejects.toThrow("symbolic links");
});
