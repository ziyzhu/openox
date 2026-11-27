import { existsSync } from "node:fs";
import { join } from "node:path";
import { ROOT, run, runCheck } from "../../../lib.ts";

const kotlinRoot = "apps/android/app/src/main/kotlin/ai/openox/ox/";
const androidOnly = ["android/", "remote/"];
const counterpartRoots: Record<string, string[]> = {
  "client/": ["apps/ios/Client/"],
  "runtime/": ["apps/shared/Runtime/", "apps/ios/Runtime/", "apps/macos/Runtime/"],
  "platform/": ["apps/shared/Platform/", "apps/ios/Platform/"],
  "diagnostics/": ["apps/shared/Diagnostics/"],
};

const mirrored = (path: string) => path.replace(/\.(swift|kt)$/, "").replaceAll("+", "").toLowerCase();

async function tracked(pattern: string): Promise<string[]> {
  const listed = await run(["git", "ls-files", "--cached", "--others", "--exclude-standard", "--", pattern], { cwd: ROOT, capture: true });
  return listed.stdout.split("\n").filter(file => file && existsSync(join(ROOT, file)));
}

export async function check(): Promise<string> {
  const kotlin = (await tracked(`${kotlinRoot}*.kt`)).map(file => file.slice(kotlinRoot.length));
  const swift = await tracked("*.swift");
  const failures: string[] = [];
  let mirroredCount = 0;
  const portedClient = new Set<string>();
  for (const file of kotlin) {
    if (androidOnly.some(prefix => file.startsWith(prefix))) continue;
    const prefix = Object.keys(counterpartRoots).find(root => file.startsWith(root));
    if (!prefix) {
      failures.push(`${kotlinRoot}${file}: place it under ${[...Object.keys(counterpartRoots), ...androidOnly].join(", ")}`);
      continue;
    }
    const relative = file.slice(prefix.length);
    const candidates = [relative, relative.replace(/Model\.kt$/, ".kt")].map(mirrored);
    const match = counterpartRoots[prefix]!.flatMap(root => swift.filter(path => path.startsWith(root) && candidates.includes(mirrored(path.slice(root.length)))))[0];
    if (!match) {
      failures.push(`${kotlinRoot}${file}: no Swift counterpart at ${counterpartRoots[prefix]!.map(root => root + relative.replace(/\.kt$/, ".swift")).join(" or ")}`);
      continue;
    }
    mirroredCount += 1;
    if (match.startsWith("apps/ios/Client/")) portedClient.add(match);
  }
  if (failures.length) throw new Error(`Android parity checks failed:\n${failures.join("\n")}`);
  const clientTotal = swift.filter(path => path.startsWith("apps/ios/Client/")).length;
  return `android parity ${mirroredCount} Kotlin files mirror Swift; ${portedClient.size}/${clientTotal} iOS Client files have an Android counterpart`;
}

if (import.meta.main) await runCheck(check);
