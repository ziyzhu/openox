import { existsSync } from "node:fs";
import { mkdtemp, readFile, readdir, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readSkills } from "../../../packages/service-sdk/src/skills.ts";
import {
  HOST_PATTERN,
  validateJSONSchemaProfile,
  validateStandardActions,
  type JSONSchema,
} from "../../../packages/service-sdk/src/manifest.ts";
import { validateIOSManifest, validateMCPManifest, type CatalogKind } from "../../../packages/services/src/catalog.ts";
import { C, fail, terminalText, type CliContext } from "./lib.ts";

type Verification = {
  passed: number;
  failed: number;
  warnings: number;
  fail(check: string, detail: string): void;
  pass(check: string): void;
  warn(check: string, detail: string): void;
};

export async function verifyRepository(args: string[], _context: CliContext): Promise<void> {
  const origin = args[0];
  if (!origin || origin === "-h" || origin === "--help") {
    console.log("Usage: ox repository verify <git-url>");
    return;
  }
  if (args.length !== 1) fail("repository verify expects one Git URL");
  validateOrigin(origin);
  const result = verification();
  const directory = await mkdtemp(join(tmpdir(), "ox-repository-verify-"));
  try {
    console.log(`Repository  ${origin}`);
    const clone = await git(["clone", "--depth=1", "--quiet", origin, directory]);
    if (!clone.ok) {
      result.fail("clone", clone.error);
      summarize(result);
      return;
    }
    result.pass("Git clone succeeded");

    const main = await git(["-C", directory, "rev-parse", "main"]);
    const mainSha = main.ok ? main.output.trim() : "";
    if (!/^[0-9a-f]{40}$/u.test(mainSha)) {
      result.fail("main ref", main.ok ? `expected a 40-character SHA, received ${JSON.stringify(mainSha)}` : main.error);
      summarize(result);
      return;
    }
    result.pass(`main → ${mainSha.slice(0, 12)}`);

    const kinds = ["web", "ios", "mcp"] as const;
    const rootDirectories = await directoryNames(directory);
    const unexpected = rootDirectories.filter(name => !name.startsWith(".") && !kinds.includes(name as typeof kinds[number]));
    if (unexpected.length) {
      result.fail("grouped service layout", `unexpected root directories: ${unexpected.join(", ")}`);
      summarize(result);
      return;
    }
    const services = (await Promise.all(kinds.map(async kind =>
      (await directoryNames(join(directory, kind))).map(id => ({ kind, id }))
    ))).flat();
    if (!services.length) {
      result.fail("services count", "0 services found");
      summarize(result);
      return;
    }
    result.pass("grouped service layout");
    result.pass(`${services.length} services discovered`);

    for (const service of services) {
      if (service.kind === "web") await checkWebService(join(directory, service.kind), service.id, result);
      else await checkCatalogService(join(directory, service.kind), service.kind, service.id, result);
    }
    await probeReceivePack(origin, result);
    summarize(result);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

function validateOrigin(origin: string): void {
  const url = parseURL(origin);
  if (url.protocol !== "https:" && !(url.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname))) {
    fail("repository verify requires an HTTPS or loopback HTTP Git URL");
  }
  if (url.username || url.password || url.hash) fail("repository URLs cannot contain credentials or fragments");
}

function parseURL(origin: string): URL {
  try {
    return new URL(origin);
  } catch {
    return fail("repository verify requires an HTTPS or loopback HTTP Git URL");
  }
}

function verification(): Verification {
  return {
    passed: 0,
    failed: 0,
    warnings: 0,
    fail(check, detail) {
      console.log(`  ${terminalText("✗", [C.bold])} ${check} — ${detail}`);
      this.failed++;
    },
    pass(check) {
      console.log(`  ${terminalText("✓", [C.sky])} ${check}`);
      this.passed++;
    },
    warn(check, detail) {
      console.log(`  ! ${check} — ${detail}`);
      this.warnings++;
    },
  };
}

async function directoryNames(path: string): Promise<string[]> {
  if (!existsSync(path)) return [];
  return (await readdir(path, { withFileTypes: true }))
    .filter(entry => entry.isDirectory())
    .map(entry => entry.name)
    .sort();
}

async function readJSON(path: string, label: string, result: Verification): Promise<any | undefined> {
  if (!existsSync(path)) {
    result.fail(label, "missing");
    return;
  }
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    result.fail(label, `invalid JSON: ${(error as Error).message}`);
  }
}

function serviceManifestPath(directory: string): string {
  const current = join(directory, "service.json");
  return existsSync(current) ? current : join(directory, "manifest.json");
}

async function checkWebService(servicesDirectory: string, domain: string, result: Verification): Promise<void> {
  const directory = join(servicesDirectory, domain);
  const manifestPath = serviceManifestPath(directory);
  const actionsPath = join(directory, "actions.js");
  const label = `web/${domain}`;
  if (!HOST_PATTERN.test(domain)) {
    result.fail(label, "invalid web service domain");
    return;
  }
  if (!existsSync(actionsPath)) {
    result.fail(`${label}: actions.js`, "missing");
    return;
  }
  const manifest = await readJSON(manifestPath, `${label}: service.json`, result);
  if (manifest === undefined) return;
  const issues = validateManifest(domain, manifest);
  if (issues.length) {
    result.fail(label, issues.join("; "));
    return;
  }
  const actionsSize = (await stat(actionsPath)).size;
  if (!actionsSize) {
    result.fail(`${label}: actions.js`, "empty");
    return;
  }
  const skills = readSkills(directory);
  if (!skills.ok) {
    result.fail(`${label}: skills`, skills.error);
    return;
  }
  const declared = manifest.skills ?? [];
  if (!Array.isArray(declared)) {
    result.fail(`${label}: manifest.skills`, "must be an array");
    return;
  }
  const normalized = declared.map((skill: any) => ({
    name: skill?.name,
    description: skill?.description,
  })).sort((left: any, right: any) => String(left.name).localeCompare(String(right.name)));
  const validShape = declared.every((skill: any) =>
    typeof skill === "object" && skill !== null
    && Object.keys(skill).every(key => key === "name" || key === "description")
    && typeof skill.name === "string" && typeof skill.description === "string");
  if (!validShape || JSON.stringify(normalized) !== JSON.stringify(skills.skills)) {
    result.fail(`${label}: skills`, "manifest catalog does not match skills/*/SKILL.md");
    return;
  }
  result.pass(`${label} — ${manifest.actions.length} actions, ${skills.skills.length} skills, ${actionsSize}B`);
}

async function checkCatalogService(
  servicesDirectory: string,
  kind: CatalogKind,
  id: string,
  result: Verification,
): Promise<void> {
  const label = `${kind}/${id}`;
  const manifest = await readJSON(serviceManifestPath(join(servicesDirectory, id)), `${label}: service.json`, result);
  if (manifest === undefined) return;
  if (kind === "ios") {
    const validated = validateIOSManifest(id, manifest);
    if ("error" in validated) result.fail(label, validated.error);
    else result.pass(`${label} — ${validated.actions.length} actions`);
    return;
  }
  const validated = validateMCPManifest(id, manifest);
  if ("error" in validated) result.fail(label, validated.error);
  else result.pass(`${label} — ${validated.transport ?? "streamable-http"}`);
}

function validateManifest(domain: string, manifest: any): string[] {
  const issues: string[] = [];
  if (typeof manifest !== "object" || manifest === null) return ["manifest is not an object"];
  if (manifest.domain !== domain) issues.push(`manifest.domain ${JSON.stringify(manifest.domain)} does not match directory ${JSON.stringify(domain)}`);
  if (typeof manifest.name !== "string" || !manifest.name) issues.push("manifest.name missing or empty");
  if (!Array.isArray(manifest.actions)) return [...issues, "manifest.actions is not an array"];
  const ids = new Set<string>();
  const definitions = typeof manifest.$defs === "object" && manifest.$defs !== null && !Array.isArray(manifest.$defs)
    ? manifest.$defs as Record<string, JSONSchema>
    : undefined;
  for (const [name, schema] of Object.entries(definitions ?? {})) {
    issues.push(...validateJSONSchemaProfile(schema, `$defs.${name}`, definitions));
  }
  for (const [index, action] of manifest.actions.entries()) {
    const label = `actions[${index}]`;
    if (typeof action !== "object" || action === null) {
      issues.push(`${label} is not an object`);
      continue;
    }
    if (typeof action.id !== "string" || !action.id) issues.push(`${label}.id missing or empty`);
    else if (ids.has(action.id)) issues.push(`${label}.id ${JSON.stringify(action.id)} is duplicate`);
    else ids.add(action.id);
    if (typeof action.inputSchema !== "object" || action.inputSchema === null) issues.push(`${label}.inputSchema missing`);
    else issues.push(...validateJSONSchemaProfile(action.inputSchema, `${label}.inputSchema`, definitions));
    if (typeof action.outputSchema !== "object" || action.outputSchema === null) issues.push(`${label}.outputSchema missing`);
    else issues.push(...validateJSONSchemaProfile(action.outputSchema, `${label}.outputSchema`, definitions));
    if (typeof action.requireAuth !== "boolean") issues.push(`${label}.requireAuth must be a boolean`);
    if (typeof action.requireApproval !== "boolean") issues.push(`${label}.requireApproval must be a boolean`);
  }
  if (!issues.length) issues.push(...validateStandardActions(manifest.actions));
  return issues;
}

async function probeReceivePack(origin: string, result: Verification): Promise<void> {
  const probe = `${origin.replace(/\/+$/u, "")}/info/refs?service=git-receive-pack`;
  try {
    const response = await fetch(probe, { redirect: "manual" });
    if (response.status === 200) result.pass("git-receive-pack advertised");
    else if (response.status === 401 || response.status === 403) result.pass(`git-receive-pack advertised and auth-gated (${response.status})`);
    else result.warn("receive-pack", `HTTP ${response.status}; repository appears read-only`);
  } catch (error) {
    result.warn("receive-pack", (error as Error).message);
  }
}

async function git(args: string[]): Promise<{ ok: true; output: string } | { ok: false; error: string }> {
  const child = Bun.spawn(["git", ...args], { stdout: "pipe", stderr: "pipe" });
  const [exitCode, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ]);
  return exitCode === 0
    ? { ok: true, output: stdout }
    : { ok: false, error: stderr.trim() || `git exited ${exitCode}` };
}

function summarize(result: Verification): void {
  const verdict = result.failed ? "FAIL" : "PASS";
  console.log(`${verdict} passed=${result.passed} failed=${result.failed} warnings=${result.warnings}`);
  if (result.failed) process.exitCode = 1;
}
