export const SYSTEM_SKILL_NAMES = ["evolve", "import-memory", "manage-providers", "manage-skills", "visualize"] as const;
export const SKILL_NAME_RE = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
export const MAXIMUM_SKILL_BYTES = 524_288;
export const MAXIMUM_SKILL_FILES = 64;

export interface SkillMeta {
  name: string;
  description: string;
  services: string[];
}

export interface Skill extends SkillMeta {
  instructions: string;
  resources: Record<string, string>;
}

export type SkillResult =
  | { ok: true; skills: Skill[] }
  | { ok: false; error: string };

export function parseSkill(text: string, name: string): Skill {
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
