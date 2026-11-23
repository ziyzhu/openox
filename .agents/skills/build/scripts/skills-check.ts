import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { ROOT, runCheck } from "../../../lib.ts";
import { parseSkill, isSkillResourcePath, SYSTEM_SKILL_NAMES, RESERVED_SKILL_NAMES } from "../../../../packages/protocol/src/skills.ts";
import { composeOxTurnSections } from "../../../../packages/agent/src/core/ox-prompts.ts";
import { bundledSkills } from "../../../../packages/agent/src/core/bundled-skills.ts";
import { validateRepositoryPackage } from "../../../../packages/protocol/src/repository.ts";
import { BUILTIN_REPOSITORY_ROOT } from "../../../../packages/services/src/service.ts";

export async function check(): Promise<string> {
  const root = join(ROOT, "packages/agent/skills");
  const files = new Map<string, string>();
  const collect = async (directory: string, target: Map<string, string>, prefix = "") => {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const relative = prefix + entry.name;
      if (!/^[a-zA-Z0-9][a-zA-Z0-9._/-]*$/.test(relative) || entry.isSymbolicLink()) throw new Error(`Invalid bundled skill resource: ${relative}`);
      if (entry.isDirectory()) await collect(join(directory, entry.name), target, relative + "/");
      else if (entry.isFile()) target.set(relative, await readFile(join(directory, entry.name), "utf8"));
      else throw new Error(`Unsupported skill resource: ${relative}`);
    }
  };
  await collect(root, files);
  const repository = validateRepositoryPackage(await Bun.file(join(BUILTIN_REPOSITORY_ROOT, "repository.json")).json(), "built-in");
  if ("error" in repository) throw new Error(repository.error);
  if (JSON.stringify([...repository.skills].sort()) !== JSON.stringify([...SYSTEM_SKILL_NAMES].sort())) throw new Error("Built-in repository skills differ from active System names");
  const mirrored = new Map<string, string>();
  await collect(join(BUILTIN_REPOSITORY_ROOT, "skills"), mirrored);
  if (mirrored.size !== files.size || [...files].some(([path, text]) => mirrored.get(path) !== text)) {
    throw new Error("Built-in repository skill files differ from packages/agent/skills; run bun run build:services");
  }
  const exported = new Map<string, string>(bundledSkills.flatMap(skill => Object.entries(skill.files).map(([path, text]) => [`${skill.name}/${path}`, text] as const)));
  if (JSON.stringify([...files.keys()].sort()) !== JSON.stringify([...exported.keys()].sort())) throw new Error("Bundled skill package inventory differs from source");
  if (JSON.stringify(bundledSkills.map(skill => skill.name).sort()) !== JSON.stringify([...SYSTEM_SKILL_NAMES].sort())) throw new Error("Bundled skill names differ from active System names");
  let bytes = 0;
  for (const [path, text] of files) {
    const size = Buffer.byteLength(text); bytes += size;
    if (!text.trim() || size > 200 * 1024 || exported.get(path) !== text) throw new Error(`Invalid or stale skill resource: ${path}`);
    const [name, ...parts] = path.split("/"); const resource = parts.join("/");
    if (resource === "SKILL.md") {
      const skill = parseSkill(text, name!);
      if (skill.description.length > 1024) throw new Error(`Skill description exceeds 1024 characters: ${name}`);
    }
    else if (!isSkillResourcePath(resource)) throw new Error(`Invalid package resource: ${path}`);
    for (const match of text.matchAll(/`((?:references|scripts)\/[a-zA-Z0-9._/-]+)`/g)) {
      if (!files.has(`${name}/${match[1]}`)) throw new Error(`Broken relative resource in ${path}: ${match[0]}`);
    }
    if (text.includes("guidance/")) throw new Error(`Retired guidance path in ${path}`);
    for (const match of text.matchAll(/`skills\/([a-z0-9-]+)\/([a-zA-Z0-9._/-]+)`/g)) {
      if ((RESERVED_SKILL_NAMES as readonly string[]).includes(match[1]!) && !files.has(`${match[1]}/${match[2]}`)) throw new Error(`Broken skill resource link in ${path}: ${match[0]}`);
    }
  }
  if (files.size > 64 || bytes > 512 * 1024) throw new Error("Bundled skills exceed native resource limits");
  const catalog = composeOxTurnSections({ skills: [...bundledSkills], skillConflicts: [], filePaths: [], storageMode: "persisted", responseLanguage: null }, { memory: "" }).skills;
  for (const name of SYSTEM_SKILL_NAMES) if (!catalog.includes(`skills/${name}/SKILL.md`)) throw new Error(`Missing System skill route: ${name}`);
  return `bundled skills ${bundledSkills.length} packages, ${files.size} files, ${bytes} bytes`;
}

if (import.meta.main) await runCheck(check);
