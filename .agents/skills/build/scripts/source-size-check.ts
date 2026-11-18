import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { ROOT, runCheck } from "../../../lib.ts";

export async function check(): Promise<string> {
  const failures: string[] = [];
  let count = 0;
  for await (const file of new Bun.Glob("apps/ios/Client/App/**/*.swift").scan(ROOT)) {
    const source = await readFile(join(ROOT, file), "utf8");
    const lines = source.trimEnd().split("\n").length;
    const bytes = Buffer.byteLength(source);
    count += 1;
    if (lines > 2_000 || bytes > 50_000) failures.push(`${file}: ${lines} lines, ${bytes} bytes; maximum 2000 lines and 50000 bytes`);
  }
  if (failures.length) throw new Error(`App source size checks failed:\n${failures.join("\n")}`);
  return `app source sizes ${count} Swift files`;
}

if (import.meta.main) await runCheck(check);
