import { readdir, readFile } from "node:fs/promises";
import { join, relative } from "node:path";
import { ROOT } from "./lib.ts";

async function swiftFiles(path: string): Promise<string[]> {
  const entries = await readdir(path, { withFileTypes: true });
  const nested = await Promise.all(entries.map((entry) => {
    const child = join(path, entry.name);
    if (entry.isDirectory()) return swiftFiles(child);
    return entry.isFile() && entry.name.endsWith(".swift") ? [child] : [];
  }));
  return nested.flat();
}

const clientRoots = [join(ROOT, "ios/ios/Views"), join(ROOT, "ios/ios/Intents")];
const files = (await Promise.all(clientRoots.map(swiftFiles))).flat();
const failures: string[] = [];

for (const file of files) {
  const source = await readFile(file, "utf8");
  for (const forbidden of ["IOSHost", "OxHost", "OxRuntime"]) {
    if (source.includes(forbidden)) {
      failures.push(`${relative(ROOT, file)}: client layer references ${forbidden}`);
    }
  }
}

const hostContract = await readFile(join(ROOT, "ios/ios/Host/OxHost.swift"), "utf8");
if (!hostContract.includes("protocol OxHost: AnyObject")) {
  failures.push("ios/ios/Host/OxHost.swift: missing OxHost contract");
}

const host = await readFile(join(ROOT, "ios/ios/Host/IOSHost.swift"), "utf8");
if (!host.includes("final class IOSHost: OxHost")) {
  failures.push("ios/ios/Host/IOSHost.swift: IOSHost must implement OxHost");
}

const client = await readFile(join(ROOT, "ios/ios/Client/OxClient.swift"), "utf8");
if (!client.includes("private let host: any OxHost")) {
  failures.push("ios/ios/Client/OxClient.swift: OxClient must target the OxHost contract");
}

const app = await readFile(join(ROOT, "ios/ios/App.swift"), "utf8");
if (!app.includes("OxClient(host: host)") || !app.includes("OxHostAPI.handle(data, host: host")) {
  failures.push("ios/ios/App.swift: composition root must connect the iOS Client and Host API to one Host");
}

const api = await readFile(join(ROOT, "ios/ios/Debug/OxHostAPI.swift"), "utf8");
if (!api.includes("host: any OxHost")) {
  failures.push("ios/ios/Debug/OxHostAPI.swift: Host API must target the OxHost contract");
}
for (const forbidden of ["viewportController", "ChatComposerModel", "setEditDraft:"]) {
  if (api.includes(forbidden)) {
    failures.push(`ios/ios/Debug/OxHostAPI.swift: UI automation state must remain in DebugUIAPI (${forbidden})`);
  }
}

if (failures.length > 0) throw new Error(`iOS Host contract failed:\n${failures.join("\n")}`);
console.log(`PASS iOS Host contract ${files.length} client files`);
