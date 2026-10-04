import { existsSync, lstatSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

import {
  SYSTEM_SKILL_NAMES, SKILL_NAME_RE, MAXIMUM_SKILL_BYTES, MAXIMUM_SKILL_FILES,
  parseSkill, isSkillResourcePath, type SkillPackage, type SkillResult,
} from "@openox/protocol/skills";

export * from "@openox/protocol/skills";

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
