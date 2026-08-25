import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { ROOT } from "./lib.ts";

const systemSkillsRoot = join(ROOT, "apps/ios/Ox/Resources/SystemSkills.bundle");
const localName = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const expectedPackages = ["manage-artifacts", "manage-services", "manage-skills"];
const expectedReferences = new Map([
  ["manage-artifacts", ["canvas.md", "note.md"]],
  ["manage-services", ["web-service.md"]],
  ["manage-skills", ["service-skill.md", "user-skill.md"]],
]);

function scalar(value: string): string {
  try {
    const decoded = JSON.parse(value);
    return typeof decoded === "string" ? decoded : value;
  } catch {
    return value;
  }
}

function validatePackage(name: string, text: string): string[] {
  const failures: string[] = [];
  if (!localName.test(name)) failures.push(`${name}: directory must use lowercase kebab-case`);
  const normalized = text.replaceAll("\r\n", "\n");
  if (!normalized.startsWith("---\n")) return [...failures, `${name}: SKILL.md must start with frontmatter`];
  const closing = normalized.indexOf("\n---\n", 4);
  if (closing < 0) return [...failures, `${name}: SKILL.md frontmatter is not closed`];
  const fields = new Map<string, string>();
  for (const line of normalized.slice(4, closing).split("\n")) {
    const separator = line.indexOf(":");
    if (separator < 0) {
      failures.push(`${name}: invalid frontmatter line ${JSON.stringify(line)}`);
      continue;
    }
    const key = line.slice(0, separator).trim();
    const value = scalar(line.slice(separator + 1).trim());
    if (fields.has(key)) failures.push(`${name}: duplicate frontmatter field ${key}`);
    fields.set(key, value);
  }
  const unknown = [...fields.keys()].filter((key) => key !== "name" && key !== "description");
  if (unknown.length > 0) failures.push(`${name}: unsupported frontmatter fields ${unknown.join(", ")}`);
  if (fields.get("name") !== name) failures.push(`${name}: frontmatter name must match its directory`);
  if (!fields.get("description")?.trim()) failures.push(`${name}: description is required`);
  if (!normalized.slice(closing + 5).trim()) failures.push(`${name}: instructions are required`);
  return failures;
}

export async function validateSystemSkills(): Promise<number> {
  const entries = await readdir(systemSkillsRoot, { withFileTypes: true });
  const packages = entries.filter((entry) => entry.isDirectory()).sort((left, right) => left.name.localeCompare(right.name));
  const failures = entries.filter((entry) => !entry.isDirectory()).map((entry) => `SystemSkills: unexpected file ${entry.name}`);
  if (packages.length === 0) failures.push("SystemSkills: no skill packages found");
  const packageNames = packages.map((entry) => entry.name);
  if (JSON.stringify(packageNames) !== JSON.stringify(expectedPackages)) {
    failures.push(`SystemSkills: expected ${expectedPackages.join(", ")}; found ${packageNames.join(", ")}`);
  }
  for (const directory of packages) {
    const path = join(systemSkillsRoot, directory.name, "SKILL.md");
    try {
      failures.push(...validatePackage(directory.name, await readFile(path, "utf8")));
    } catch (error) {
      failures.push(`${directory.name}: cannot read SKILL.md: ${error instanceof Error ? error.message : String(error)}`);
    }
    const referencesRoot = join(systemSkillsRoot, directory.name, "references");
    try {
      const references = (await readdir(referencesRoot, { withFileTypes: true }))
        .filter((entry) => entry.isFile())
        .map((entry) => entry.name)
        .sort((left, right) => left.localeCompare(right));
      const expected = expectedReferences.get(directory.name) ?? [];
      if (JSON.stringify(references) !== JSON.stringify(expected)) {
        failures.push(`${directory.name}: expected references ${expected.join(", ")}; found ${references.join(", ")}`);
      }
      for (const reference of references) {
        if (!reference.endsWith(".md") || !localName.test(reference.slice(0, -3))) {
          failures.push(`${directory.name}: invalid reference name ${reference}`);
        }
        if (!(await readFile(join(referencesRoot, reference), "utf8")).trim()) {
          failures.push(`${directory.name}: empty reference ${reference}`);
        }
      }
    } catch (error) {
      failures.push(`${directory.name}: cannot read references: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  if (failures.length > 0) throw new Error(`System skill validation failed:\n${failures.join("\n")}`);
  return packages.length;
}

if (import.meta.main) {
  try {
    const count = await validateSystemSkills();
    console.log(`PASS system skills ${count} packages`);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
