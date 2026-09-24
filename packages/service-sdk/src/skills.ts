import { existsSync, lstatSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

export const SYSTEM_SKILL_NAMES = ["manage-artifacts", "manage-services", "manage-skills"] as const;
export const SKILL_NAME_RE = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
export const MAXIMUM_SKILL_BYTES = 524_288;
export const MAXIMUM_SKILL_FILES = 64;

export interface SkillMeta {
  name: string;
  description: string;
  services: string[];
}

export interface SkillPackage extends SkillMeta {
  instructions: string;
  resources: Record<string, string>;
}

export type SkillResult =
  | { ok: true; skills: SkillPackage[] }
  | { ok: false; error: string };

export function parseSkill(text: string, name: string): SkillPackage {
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n([\s\S]*)$/.exec(text);
  if (!match || (!SKILL_NAME_RE.test(name) || name.length > 100)) throw new Error(`${name}: invalid skill frontmatter`);
  const fields: Record<string, string> = {};
  for (const raw of match[1]!.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    const pair = /^([A-Za-z_][\w-]*):\s*(.*)$/.exec(line);
    if (!pair) throw new Error(`${name}: frontmatter fields must occupy one line`);
    const key = pair[1]!;
    if (!["name", "description", "services"].includes(key) || key in fields) throw new Error(`${name}: invalid field ${key}`);
    const value = pair[2]!.trim();
    fields[key] = value.startsWith('"') ? JSON.parse(value) : value;
    if (typeof fields[key] !== "string") throw new Error(`${name}: ${key} must be text`);
  }
  const description = fields.description?.trim();
  const instructions = match[2]!.trim();
  if (fields.name !== name || !description || !instructions) throw new Error(`${name}: name, description, and instructions are required`);
  const services = [...new Set((fields.services ?? "").split(",").map(value => value.trim()).filter(Boolean))];
  if (services.some(service => !/^[a-z0-9]+(?:[.:-][a-z0-9]+)*$/.test(service))) throw new Error(`${name}: invalid service dependency`);
  return { name, description, instructions, services, resources: {} };
}

export function isSkillResourcePath(path: string): boolean {
  const parts = path.split("/");
  return parts.length >= 2 && ["references", "scripts"].includes(parts[0]!)
    && parts.slice(1).every(part => /^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(part))
    && (parts[0] !== "scripts" || path.endsWith(".js"));
}

export function readSkill(directory: string, name: string): SkillPackage {
  const files: Record<string, string> = {};
  let total = 0;
  function collect(root: string, relative = ""): void {
    const metadata = lstatSync(root);
    if (metadata.isSymbolicLink() || !metadata.isDirectory()) throw new Error(`${name}: invalid directory ${relative}`);
    for (const entry of readdirSync(root, { withFileTypes: true })) {
      const path = relative ? `${relative}/${entry.name}` : entry.name;
      const fullPath = join(root, entry.name);
      const info = lstatSync(fullPath);
      if (info.isSymbolicLink()) throw new Error(`${name}: symbolic links are unsupported`);
      if (info.isDirectory()) {
        if (!["references", "scripts"].includes(path) && !isSkillResourcePath(`${path}/file.js`)) throw new Error(`${name}: invalid directory ${path}`);
        collect(fullPath, path);
      } else {
        if (!info.isFile() || (path !== "SKILL.md" && !isSkillResourcePath(path))) throw new Error(`${name}: invalid file ${path}`);
        total += info.size;
        if (total > MAXIMUM_SKILL_BYTES || Object.keys(files).length >= MAXIMUM_SKILL_FILES) throw new Error(`${name}: skill package is too large`);
        files[path] = new TextDecoder("utf-8", { fatal: true }).decode(readFileSync(fullPath));
      }
    }
  }
  collect(directory);
  if (!files["SKILL.md"]) throw new Error(`${name}: SKILL.md is missing`);
  const skill = parseSkill(files["SKILL.md"], name);
  delete files["SKILL.md"];
  return { ...skill, resources: files };
}

export function readSkills(repositoryDir: string, declared?: readonly string[]): SkillResult {
  const root = join(repositoryDir, "skills");
  try {
    if (existsSync(root) && lstatSync(root).isSymbolicLink()) throw new Error("symbolic skill roots are unsupported");
    const names = declared ?? (existsSync(root) ? readdirSync(root) : []);
    if (new Set(names).size !== names.length) throw new Error("duplicate skill names");
    const skills = names.map(name => {
      if (!SKILL_NAME_RE.test(name) || SYSTEM_SKILL_NAMES.some(reserved => reserved === name)) throw new Error(`invalid or reserved skill name: ${name}`);
      return readSkill(join(root, name), name);
    });
    return { ok: true, skills: skills.sort((a, b) => a.name.localeCompare(b.name)) };
  } catch (error) {
    return { ok: false, error: (error as Error).message };
  }
}
