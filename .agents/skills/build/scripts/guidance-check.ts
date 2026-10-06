import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { ROOT, runCheck } from "../../../lib.ts";
import { oxScaffold } from "../../../../packages/agent/src/core/ox-prompts.ts";

const root = join(ROOT, "apps/ios/Ox/Resources/ModelGuidance.bundle");
const expected = new Map([
  ["evolve", ["api-service.md", "helpers.js", "model-schemas.md", "model-service.md", "web-service.md"]],
  ["import-memory", []],
  ["manage-providers", []],
  ["manage-skills", ["repository-skill.md", "user-skill.md"]],
  ["visualize", ["canvas.md"]],
]);

export async function check(): Promise<string> {
  const files = new Map<string, string>();
  const collect = async (directory: string, prefix = "") => {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const relative = prefix + entry.name;
      if (!/^[a-zA-Z0-9][a-zA-Z0-9._/-]*$/.test(relative) || entry.isSymbolicLink()) throw new Error(`Invalid guidance resource: ${relative}`);
      if (entry.isDirectory()) await collect(join(directory, entry.name), relative + "/");
      else if (entry.isFile()) files.set(relative, await readFile(join(directory, entry.name), "utf8"));
      else throw new Error(`Unsupported guidance resource: ${relative}`);
    }
  };
  await collect(root);
  const expectedPaths = [...expected].flatMap(([name, references]) => [`${name}/guide.md`, ...references.map(path => `${name}/references/${path}`)]).sort();
  if (JSON.stringify([...files.keys()].sort()) !== JSON.stringify(expectedPaths)) throw new Error("Built-in guidance inventory differs from the expected workflows and references");
  let bytes = 0;
  for (const [path, text] of files) {
    const size = Buffer.byteLength(text);
    bytes += size;
    if (!text.trim() || size > 200 * 1024) throw new Error(`Empty or oversized guidance: ${path}`);
    if (path.endsWith("/guide.md") && (!text.startsWith("# ") || text.startsWith("---"))) throw new Error(`Guidance must be documentation, not a skill package: ${path}`);
  }
  if (files.size > 64 || bytes > 512 * 1024) throw new Error("Built-in guidance exceeds runtime limits");
  const index = oxScaffold.guidance ?? "";
  for (const name of expected.keys()) {
    if (!index.includes(`guidance/${name}/guide.md`)) throw new Error(`Missing prompt route for ${name}`);
  }
  for (const [path, text] of [...files, ["system prompt", index] as const]) {
    for (const match of text.matchAll(/`guidance\/([a-zA-Z0-9._/-]+)`/g)) {
      if (!files.has(match[1]!)) throw new Error(`Broken guidance link in ${path}: ${match[0]}`);
    }
    if (/skills\/(evolve|import-memory|manage-providers|manage-skills|visualize)\//.test(text)) throw new Error(`Retired system-skill path in ${path}`);
  }
  return `built-in guidance ${expected.size} workflows, ${files.size} files, ${bytes} bytes`;
}

if (import.meta.main) await runCheck(check);
