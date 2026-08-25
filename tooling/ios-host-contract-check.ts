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

const clientRoots = [
  join(ROOT, "apps/ios/OpenOx/Client/Features"),
  join(ROOT, "apps/ios/OpenOx/Client/Intents"),
  join(ROOT, "apps/ios/OpenOx/Client/UI"),
];
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

const hostContract = await readFile(join(ROOT, "apps/ios/OpenOx/Host/OxHost.swift"), "utf8");
if (!hostContract.includes("protocol OxHost: AnyObject")) {
  failures.push("apps/ios/OpenOx/Host/OxHost.swift: missing OxHost contract");
}

const host = await readFile(join(ROOT, "apps/ios/OpenOx/Host/IOSHost.swift"), "utf8");
if (!host.includes("final class IOSHost: OxHost")) {
  failures.push("apps/ios/OpenOx/Host/IOSHost.swift: IOSHost must implement OxHost");
}

const client = await readFile(join(ROOT, "apps/ios/OpenOx/Client/OxClient.swift"), "utf8");
if (!client.includes("private let host: any OxHost")) {
  failures.push("apps/ios/OpenOx/Client/OxClient.swift: OxClient must target the OxHost contract");
}

const app = await readFile(join(ROOT, "apps/ios/OpenOx/Client/App/App.swift"), "utf8");
if (!app.includes("OxClient(host: host)") || !app.includes("WebSocketOxHostTransport(host: host)")) {
  failures.push("apps/ios/OpenOx/Client/App/App.swift: composition root must connect in-process and WebSocket transports to one Host");
}

const hostProtocol = await readFile(join(ROOT, "apps/ios/OpenOx/Host/OxHostProtocol.swift"), "utf8");
if (!hostProtocol.includes("host: any OxHost")) {
  failures.push("apps/ios/OpenOx/Host/OxHostProtocol.swift: Host protocol must target the OxHost contract");
}
for (const forbidden of ["viewportController", "ChatComposerModel", "setEditDraft:"]) {
  if (hostProtocol.includes(forbidden)) {
    failures.push(`apps/ios/OpenOx/Host/OxHostProtocol.swift: UI automation state must remain in DebugUIAPI (${forbidden})`);
  }
}

const webSocketTransport = await readFile(
  join(ROOT, "apps/ios/OpenOx/Host/WebSocketOxHostTransport.swift"),
  "utf8",
);
if (!webSocketTransport.includes("OxHostProtocol.handle(data, host: self.host)")) {
  failures.push("apps/ios/OpenOx/Host/WebSocketOxHostTransport.swift: WebSocket transport must dispatch through OxHostProtocol");
}
if (webSocketTransport.includes("onCommand")) {
  failures.push("apps/ios/OpenOx/Host/WebSocketOxHostTransport.swift: transport must bind directly to its Host");
}

const allSource = await Promise.all((await swiftFiles(join(ROOT, "apps/ios/OpenOx"))).map((file) => readFile(file, "utf8")));
if (allSource.some((source) => source.includes("DebugServer") || source.includes("OxHostAPI"))) {
  failures.push("apps/ios/OpenOx: legacy DebugServer or OxHostAPI reference remains");
}

if (failures.length > 0) throw new Error(`iOS Host contract failed:\n${failures.join("\n")}`);
console.log(`PASS iOS Host contract ${files.length} client files`);
