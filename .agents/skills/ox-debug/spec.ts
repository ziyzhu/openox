import { mkdtemp, rm, readdir, readFile, stat } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { dispatch, fail, header, info, need, ok, sh, sh$, step, C, type SubCommand } from "./lib.ts";
import { readSkills } from "../../../ox-cli/server-ir/skills.ts";
import { validateIOSManifest, validateMCPManifest, type CatalogKind } from "../../../ox-cli/server-ir/catalog.ts";
import {
  HOST_PATTERN,
  validateJSONSchemaProfile,
  validateStandardActions,
  type JSONSchema,
} from "../../../ox-cli/server-ir/manifest.ts";

export const SUBS: Record<string, SubCommand> = {
  verify: {
    desc: "Verify a git URL conforms to the Ox Server IR (WHITE_PAPER §6)",
    fn: verify,
  },
};

export async function spec(args: string[]): Promise<void> {
  return dispatch("spec", "Protocol conformance checks.", SUBS, args);
}

interface Result {
  passed: number;
  failed: number;
  warnings: number;
  fail(check: string, detail: string): void;
  pass(check: string): void;
  warn(check: string, detail: string): void;
}

function newResult(): Result {
  return {
    passed: 0, failed: 0, warnings: 0,
    fail(check, detail) { console.log(`  ${C.red}✗${C.reset} ${check} — ${detail}`); this.failed++; },
    pass(check) { console.log(`  ${C.green}✓${C.reset} ${check}`); this.passed++; },
    warn(check, detail) { console.log(`  ${C.dim}!${C.reset} ${check} — ${detail}`); this.warnings++; },
  };
}

async function verify(args: string[]): Promise<void> {
  const url = args[0];
  if (!url || url === "-h" || url === "--help") {
    console.log("Usage: debug spec verify <git-url>\n");
    console.log("Clones the URL and asserts it satisfies the Server IR:");
    console.log("  - main ref exists");
    console.log("  - tree contains web/<domain>, ios/<id>, and mcp/<id> service definitions");
    console.log("  - each manifest.json has the required shape");
    console.log("  - git-receive-pack capability is probed (informational)\n");
    return;
  }

  need("git");
  const r = newResult();
  const work = await mkdtemp(join(tmpdir(), "ox-spec-"));
  try {
    header("debug spec verify", url);

    step("\nClone");
    const isHTTP = /^https?:/i.test(url);
    const cloneArgs = isHTTP
      ? ["git", "clone", "--depth=1", "--quiet", url, work]
      : ["git", "clone", "--quiet", url, work];
    const clone = await sh(cloneArgs, { check: false });
    if (clone !== 0) { r.fail("clone", "git clone failed (see output above)"); return summarize(r); }
    r.pass("git clone succeeded");

    step("\nMain ref");
    const mainSha = (await sh$(["git", "-C", work, "rev-parse", "main"], { check: false })).trim();
    if (!/^[0-9a-f]{40}$/.test(mainSha)) {
      r.fail("main ref", `expected a 40-char SHA, got "${mainSha}"`);
      return summarize(r);
    }
    r.pass(`main → ${mainSha.slice(0, 12)}`);

    step("\nLayout");
    const kinds = ["web", "ios", "mcp"] as const;
    const rootDirectories = await directoryNames(work);
    const unexpected = rootDirectories.filter(name => !name.startsWith(".") && !kinds.includes(name as typeof kinds[number]));
    if (unexpected.length > 0) {
      r.fail("grouped service layout", `unexpected root directories: ${unexpected.join(", ")}`);
      return summarize(r);
    }

    const services = (await Promise.all(kinds.map(async kind =>
      (await directoryNames(join(work, kind))).map(id => ({ kind, id }))
    ))).flat();
    if (services.length === 0) {
      r.fail("services count", "0 services found");
      return summarize(r);
    }
    const counts = kinds.map(kind => `${kind}=${services.filter(service => service.kind === kind).length}`).join(" ");
    r.pass("grouped service layout");
    r.pass(`${services.length} services discovered (${counts})`);

    step("\nServices");
    for (const service of services) {
      if (service.kind === "web") await checkWebService(join(work, service.kind), service.id, r);
      else await checkCatalogService(join(work, service.kind), service.kind, service.id, r);
    }

    step("\nReceive-pack (optional)");
    await probeReceivePack(url, r);

    summarize(r);
  } finally {
    await rm(work, { recursive: true, force: true });
  }
}

async function directoryNames(path: string): Promise<string[]> {
  if (!existsSync(path)) return [];
  return (await readdir(path, { withFileTypes: true }))
    .filter(entry => entry.isDirectory())
    .map(entry => entry.name)
    .sort();
}

async function readJSON(path: string, label: string, r: Result): Promise<any | undefined> {
  if (!existsSync(path)) {
    r.fail(label, "missing");
    return undefined;
  }
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    r.fail(label, `invalid JSON: ${(error as Error).message}`);
    return undefined;
  }
}

async function checkWebService(servicesDir: string, domain: string, r: Result): Promise<void> {
  const dir = join(servicesDir, domain);
  const manifestPath = join(dir, "manifest.json");
  const actionsPath = join(dir, "actions.js");
  const faviconPath = join(dir, "favicon.png");
  const label = `web/${domain}`;

  if (!HOST_PATTERN.test(domain)) { r.fail(label, "invalid web service domain"); return; }
  if (!existsSync(actionsPath)) { r.fail(`${label}: actions.js`, "missing"); return; }

  const manifest = await readJSON(manifestPath, `${label}: manifest.json`, r);
  if (manifest === undefined) return;

  const issues = validateManifest(domain, manifest);
  if (issues.length) {
    r.fail(label, issues.join("; "));
    return;
  }

  const actionsSize = (await stat(actionsPath)).size;
  if (actionsSize === 0) { r.fail(`${label}: actions.js`, "empty"); return; }

  const skillResult = readSkills(dir);
  if (!skillResult.ok) { r.fail(`${label}: skills`, skillResult.error); return; }
  const declaredSkills = manifest.skills ?? [];
  if (!Array.isArray(declaredSkills)) { r.fail(`${label}: manifest.skills`, "must be an array"); return; }
  const normalizedSkills = declaredSkills.map((skill: any) => ({
    name: skill?.name,
    description: skill?.description,
  })).sort((a: any, b: any) => String(a.name).localeCompare(String(b.name)));
  const validSkillShape = declaredSkills.every((skill: any) =>
    typeof skill === "object" && skill !== null
    && Object.keys(skill).every(key => key === "name" || key === "description")
    && typeof skill.name === "string" && typeof skill.description === "string");
  if (!validSkillShape || JSON.stringify(normalizedSkills) !== JSON.stringify(skillResult.skills)) {
    r.fail(`${label}: skills`, "manifest catalog does not match skills/*/SKILL.md");
    return;
  }

  const favNote = existsSync(faviconPath) ? "" : " (no favicon.png)";
  const skillNote = skillResult.skills.length ? `, ${skillResult.skills.length} skill${skillResult.skills.length === 1 ? "" : "s"}` : "";
  r.pass(`${label} — ${manifest.actions.length} action${manifest.actions.length === 1 ? "" : "s"}${skillNote}, ${actionsSize}B${favNote}`);
}

async function checkCatalogService(servicesDir: string, kind: CatalogKind, id: string, r: Result): Promise<void> {
  const label = `${kind}/${id}`;
  const manifest = await readJSON(join(servicesDir, id, "manifest.json"), `${label}: manifest.json`, r);
  if (manifest === undefined) return;
  if (kind === "ios") {
    const validated = validateIOSManifest(id, manifest);
    if ("error" in validated) { r.fail(label, validated.error); return; }
    r.pass(`${label} — ${validated.actions.length} action${validated.actions.length === 1 ? "" : "s"}`);
    return;
  }
  const validated = validateMCPManifest(id, manifest);
  if ("error" in validated) { r.fail(label, validated.error); return; }
  r.pass(`${label} — ${validated.transport ?? "streamable-http"}`);
}

function validateManifest(domain: string, m: any): string[] {
  const issues: string[] = [];
  if (typeof m !== "object" || m === null) return ["manifest is not an object"];
  if (m.domain !== domain) issues.push(`manifest.domain "${m.domain}" ≠ directory "${domain}"`);
  if (typeof m.name !== "string" || !m.name) issues.push("manifest.name missing or empty");
  if (!Array.isArray(m.actions)) { issues.push("manifest.actions is not an array"); return issues; }

  const ids = new Set<string>();
  const defs = typeof m.$defs === "object" && m.$defs !== null && !Array.isArray(m.$defs)
    ? m.$defs as Record<string, JSONSchema>
    : undefined;
  for (const [name, schema] of Object.entries(defs ?? {})) {
    issues.push(...validateJSONSchemaProfile(schema, `$defs.${name}`, defs));
  }
  for (const [i, a] of m.actions.entries()) {
    const tag = `actions[${i}]`;
    if (typeof a !== "object" || a === null) { issues.push(`${tag} is not an object`); continue; }
    if (typeof a.id !== "string" || !a.id) issues.push(`${tag}.id missing or empty`);
    else if (ids.has(a.id)) issues.push(`${tag}.id "${a.id}" is duplicate`);
    else ids.add(a.id);
    if (typeof a.inputSchema !== "object" || a.inputSchema === null) issues.push(`${tag}.inputSchema missing`);
    if (typeof a.outputSchema !== "object" || a.outputSchema === null) issues.push(`${tag}.outputSchema missing`);
    else issues.push(...validateJSONSchemaProfile(a.outputSchema, `${tag}.outputSchema`, defs));
    if (typeof a.inputSchema === "object" && a.inputSchema !== null) {
      issues.push(...validateJSONSchemaProfile(a.inputSchema, `${tag}.inputSchema`, defs));
    }
    if (typeof a.requireAuth !== "boolean") issues.push(`${tag}.requireAuth must be a boolean`);
    if (typeof a.requireApproval !== "boolean") issues.push(`${tag}.requireApproval must be a boolean`);
  }
  if (issues.length === 0) issues.push(...validateStandardActions(m.actions));
  return issues;
}

async function probeReceivePack(url: string, r: Result): Promise<void> {
  const refs = await sh$(["git", "ls-remote", url], { check: false });
  if (!refs) { r.warn("receive-pack", "ls-remote produced no output"); return; }

  const out = await sh$(["git", "ls-remote", "--symref", url, "HEAD"], { check: false });
  void out;

  const httpUrl = url.startsWith("http") ? url : null;
  if (!httpUrl) { r.warn("receive-pack", "non-HTTP URL; skipping smart-HTTP capability probe"); return; }
  const probeUrl = `${httpUrl.replace(/\/+$/, "")}/info/refs?service=git-receive-pack`;
  const status = await sh$(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", probeUrl], { check: false });
  const code = status.trim();
  if (code === "200") r.pass("git-receive-pack advertised (push-capable)");
  else if (code === "401" || code === "403") r.pass(`git-receive-pack advertised (auth-gated, HTTP ${code})`);
  else r.warn("receive-pack", `HTTP ${code} — server appears read-only (still conformant)`);
}

function summarize(r: Result): void {
  console.log("");
  const verdict = r.failed === 0 ? `${C.green}PASS${C.reset}` : `${C.red}FAIL${C.reset}`;
  info(`${verdict}  passed=${r.passed} failed=${r.failed} warnings=${r.warnings}`);
  if (r.failed > 0) process.exit(1);
}
