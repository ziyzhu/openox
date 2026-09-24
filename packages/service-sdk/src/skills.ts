import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

export interface SkillMeta {
  name: string;
  description: string;
}

export type SkillResult =
  | { ok: true; skills: SkillMeta[] }
  | { ok: false; error: string };

const SKILL_NAME_RE = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

function parseSkill(text: string): { fields: Record<string, string>; body: string } | null {
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/.exec(text);
  if (!match) return null;
  const fields: Record<string, string> = {};
  let key: string | null = null;
  for (const line of match[1]!.split(/\r?\n/)) {
    if (key && /^\s+\S/.test(line)) {
      fields[key] += " " + line.trim();
      continue;
    }
    const pair = /^([A-Za-z_][\w-]*):\s*(.*)$/.exec(line);
    if (!pair) {
      key = null;
      continue;
    }
    key = pair[1]!;
    fields[key] = pair[2]!.trim().replace(/^(?:"([\s\S]*)"|'([\s\S]*)')$/, "$1$2");
  }
  return { fields, body: match[2]!.trim() };
}

export function readSkills(serviceDir: string): SkillResult {
  const root = join(serviceDir, "skills");
  if (!existsSync(root)) return { ok: true, skills: [] };
  const skills: SkillMeta[] = [];
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    if (!entry.isDirectory()) {
      return { ok: false, error: `skills/${entry.name}: expected a skill directory` };
    }
    if (!SKILL_NAME_RE.test(entry.name)) {
      return { ok: false, error: `skills/${entry.name}: invalid skill name` };
    }
    const path = join(root, entry.name, "SKILL.md");
    if (!existsSync(path)) {
      return { ok: false, error: `skills/${entry.name}/SKILL.md: missing` };
    }
    const unsupported = readdirSync(join(root, entry.name), { withFileTypes: true })
      .find((child) => child.name !== "SKILL.md" || !child.isFile());
    if (unsupported) {
      return { ok: false, error: `skills/${entry.name}/${unsupported.name}: bundled resources are not supported` };
    }
    const parsed = parseSkill(readFileSync(path, "utf8"));
    if (!parsed) {
      return { ok: false, error: `skills/${entry.name}/SKILL.md: frontmatter is required` };
    }
    if (parsed.fields.name !== entry.name) {
      return { ok: false, error: `skills/${entry.name}/SKILL.md: name must equal "${entry.name}"` };
    }
    const description = parsed.fields.description?.trim();
    if (!description) {
      return { ok: false, error: `skills/${entry.name}/SKILL.md: description is required` };
    }
    if (!parsed.body) {
      return { ok: false, error: `skills/${entry.name}/SKILL.md: body is required` };
    }
    skills.push({ name: entry.name, description });
  }
  skills.sort((a, b) => a.name.localeCompare(b.name));
  return { ok: true, skills };
}
