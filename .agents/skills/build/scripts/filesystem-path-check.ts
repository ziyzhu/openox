import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { ROOT, runCheck } from "../../../lib.ts";

export async function check(): Promise<string> {
  const failures: string[] = [];
  let count = 0;
  const patterns = [
    /\.path\s*\.\s*dropFirst\([^)]*\.path\s*\.count/g,
    /\.path\s*\.\s*replacingOccurrences\(\s*of:\s*[\w.]+\.path\b/g,
    /\.standardizedFileURL\s*\.\s*path\s*\.\s*dropFirst\(/g,
  ];
  for await (const file of new Bun.Glob("apps/ios/**/*.swift").scan(ROOT)) {
    const source = await readFile(join(ROOT, file), "utf8");
    count += 1;
    for (const pattern of patterns) {
      for (const match of source.matchAll(pattern)) {
        const line = source.slice(0, match.index).split("\n").length;
        failures.push(`${file}:${line}: derive relative paths from entry names or enumeration depth, not absolute-path string arithmetic`);
      }
    }
  }
  if (failures.length) throw new Error(`Filesystem path checks failed:\n${failures.join("\n")}`);
  return `filesystem paths ${count} Swift files`;
}

if (import.meta.main) await runCheck(check);
