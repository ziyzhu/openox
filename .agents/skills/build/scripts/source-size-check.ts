import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { ROOT, run, runCheck } from "../../../lib.ts";

const maximumLines = 2_000;
const maximumBytes = 50_000;
const oversized: Record<string, number> = {
  "apps/shared/Host/Conversations/Conversation.swift": 88_417,
  "apps/ios/Client/Features/Conversation/ConversationPage.swift": 83_973,
  "apps/shared/Host/Conversations/ConversationManager.swift": 55_708,
  "packages/agent/src/adapters/ios/agent.ts": 53_281,
  "apps/shared/Host/Services/ServiceManager.swift": 51_682,
};

export async function check(): Promise<string> {
  const listed = await run(["git", "ls-files", "--cached", "--others", "--exclude-standard", "--", "*.swift", "*.ts", "*.tsx", "*.kt"], { cwd: ROOT, capture: true });
  const files = listed.stdout.split("\n").filter(file => file && !file.endsWith(".d.ts"));
  const failures: string[] = [];
  let count = 0;
  for (const file of files) {
    const source = await readFile(join(ROOT, file), "utf8").catch(() => undefined);
    if (source === undefined) continue;
    const lines = source.trimEnd().split("\n").length;
    const bytes = Buffer.byteLength(source);
    const byteLimit = oversized[file] ?? maximumBytes;
    count += 1;
    if (lines > maximumLines || bytes > byteLimit) failures.push(`${file}: ${lines} lines, ${bytes} bytes; maximum ${maximumLines} lines and ${byteLimit} bytes`);
  }
  for (const file of Object.keys(oversized)) {
    if (!files.includes(file)) failures.push(`${file}: listed as oversized but no longer exists; remove it from the list`);
  }
  if (failures.length) throw new Error(`Source size checks failed:\n${failures.join("\n")}`);
  return `source sizes ${count} files, ${Object.keys(oversized).length} capped at their current size`;
}

if (import.meta.main) await runCheck(check);
