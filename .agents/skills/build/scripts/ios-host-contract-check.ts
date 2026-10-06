import { readdir, readFile } from "node:fs/promises";
import { join, relative } from "node:path";
import { ROOT, runCheck } from "../../../lib.ts";

async function swiftFiles(path: string): Promise<string[]> {
  const entries = await readdir(path, { withFileTypes: true });
  const nested = await Promise.all(entries.map((entry) => {
    const child = join(path, entry.name);
    if (entry.isDirectory()) return swiftFiles(child);
    return entry.isFile() && entry.name.endsWith(".swift") ? [child] : [];
  }));
  return nested.flat();
}

export async function check(): Promise<string> {
  const clientRoots = [
    join(ROOT, "apps/ios/Ox/Client/Features"),
    join(ROOT, "apps/ios/Ox/Client/UI"),
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

  const hostContract = await readFile(join(ROOT, "apps/ios/Ox/Host/OxHost.swift"), "utf8");
  if (!hostContract.includes("protocol OxHost: AnyObject")) {
    failures.push("apps/ios/Ox/Host/OxHost.swift: missing OxHost contract");
  }

  const host = await readFile(join(ROOT, "apps/ios/Ox/Host/IOSHost.swift"), "utf8");
  if (!host.includes("final class IOSHost: OxHost")) {
    failures.push("apps/ios/Ox/Host/IOSHost.swift: IOSHost must implement OxHost");
  }
  if (!host.includes("StorageMigrator.prepare")) {
    failures.push("apps/ios/Ox/Host/IOSHost.swift: Host preparation must pass through StorageMigrator");
  }

  const client = await readFile(join(ROOT, "apps/ios/Ox/Client/OxClient.swift"), "utf8");
  if (!client.includes("private let host: any OxHost")) {
    failures.push("apps/ios/Ox/Client/OxClient.swift: OxClient must target the OxHost contract");
  }

  const app = await readFile(join(ROOT, "apps/ios/Ox/Client/App/App.swift"), "utf8");
  if (!app.includes("OxClient(host: host)") || !app.includes("WebSocketOxHostTransport(host: host, access: access)")) {
    failures.push("apps/ios/Ox/Client/App/App.swift: composition root must connect in-process and WebSocket transports to one Host");
  }

  const hostProtocol = await readFile(join(ROOT, "apps/ios/Ox/Host/OxHostProtocol.swift"), "utf8");
  if (!hostProtocol.includes("host: any OxHost")) {
    failures.push("apps/ios/Ox/Host/OxHostProtocol.swift: Host protocol must target the OxHost contract");
  }
  for (const forbidden of ["viewportController", "ChatComposerModel", "var setEditDraft"]) {
    if (hostProtocol.includes(forbidden)) {
      failures.push(`apps/ios/Ox/Host/OxHostProtocol.swift: UI automation state must remain in ClientAutomation (${forbidden})`);
    }
  }

  const webSocketTransport = await readFile(
    join(ROOT, "apps/ios/Ox/Host/WebSocketOxHostTransport.swift"),
    "utf8",
  );
  if (!webSocketTransport.includes("OxHostProtocol.handle(data, host: self.host, admit:")) {
    failures.push("apps/ios/Ox/Host/WebSocketOxHostTransport.swift: WebSocket transport must dispatch through OxHostProtocol");
  }
  for (const path of [
    "apps/ios/Ox/Host/WebSocketOxHostTransport.swift",
    "apps/ios/Ox/Host/OxHostRPC.swift",
    "apps/ios/Ox/Host/OxHostProtocol.swift",
    "apps/ios/Ox/Host/OxHostProtocolMessages.swift",
    "apps/ios/Ox/Host/RPC/HostRPCRequests.swift",
    "apps/ios/Ox/Host/Profile/StorageRoot.swift",
    "apps/ios/Ox/Host/Services/ServiceDebug.swift",
    "apps/ios/Ox/Host/Profile/ProfileRepositorySaveGate.swift",
    ...["ChatCommands", "ServiceCommands", "BootstrapCommands", "AgentEvals"].map(name => `apps/ios/Ox/Host/RPC/${name}.swift`),
    ...["ComposerCommands", "ClientAutomation"].map(name => `apps/ios/Ox/Client/Automation/${name}.swift`),
  ]) {
    const source = await readFile(join(ROOT, path), "utf8");
    if (source.includes("#if targetEnvironment(simulator)") || source.includes("#if DEBUG")) {
      failures.push(`${path}: Client–Host capabilities must not depend on build or Simulator`);
    }
  }
  for (const required of ["parameters.requiredInterface = ingress.interface", "parameters.requiredLocalEndpoint = .hostPort", "TailscaleHostIngress.current(on:", "pathUpdateHandler", "self.hasCurrentIngress(client)"]) {
    if (!webSocketTransport.includes(required)) failures.push(`WebSocket transport must enforce VPN-only ingress (${required})`);
  }
  if (webSocketTransport.includes(".loopback") || webSocketTransport.includes("NWListener(using: parameters, on:")) {
    failures.push("WebSocket transport must not expose a loopback or unrestricted listener");
  }
  if (app.includes("WebSocketOxHostTransport.configuredPort != nil")) {
    failures.push("Foreground Host access must not require launch configuration");
  }
  if (!webSocketTransport.includes("guard access.enabled, prepared") || !webSocketTransport.includes("access.onEnabledChange")) {
    failures.push("Host access must be opt-in and stop immediately when disabled");
  }
  const ingress = await readFile(join(ROOT, "apps/ios/Ox/Host/TailscaleHostIngress.swift"), "utf8");
  for (const required of ["interface.type == .other", "ipv4.count == 1, ipv6.count == 1", "candidates.count == 1", "path.availableInterfaces.allSatisfy({ $0.index == interface.index })"]) {
    if (!ingress.includes(required)) failures.push(`Tailscale ingress must fail closed (${required})`);
  }
  if (ingress.includes("#if DEBUG") || ingress.includes("#if targetEnvironment(simulator)")) {
    failures.push("Tailscale ingress must not depend on build or Simulator");
  }
  if (webSocketTransport.includes("onCommand")) {
    failures.push("apps/ios/Ox/Host/WebSocketOxHostTransport.swift: transport must bind directly to its Host");
  }

  const allSwiftFiles = await swiftFiles(join(ROOT, "apps/ios/Ox"));
  const allSource = await Promise.all(allSwiftFiles.map((file) => readFile(file, "utf8")));
  if (allSource.some((source) => source.includes("DebugServer") || source.includes("OxHostAPI"))) {
    failures.push("apps/ios/Ox: legacy DebugServer or OxHostAPI reference remains");
  }

  const storageMigrationCallers = new Set([
    "apps/ios/Ox/Host/IOSHost.swift",
    "apps/ios/Ox/Host/Profile/StorageMigration.swift",
    "apps/ios/Ox/Host/Profile/StorageRoot.swift",
    "apps/ios/Ox/Host/Durable/DurableProfileStore.swift",
    "apps/ios/Ox/Host/Services/Repository/Repository.swift",
  ]);
  for (const [index, source] of allSource.entries()) {
    const path = relative(ROOT, allSwiftFiles[index]);
    if (source.includes("ProfileMigrator") || source.includes("ProfileMigrationError")) {
      failures.push(`${path}: StorageMigrator must be the only persisted-storage migrator`);
    }
    if (source.includes("StorageMigrator.") && !storageMigrationCallers.has(path)) {
      failures.push(`${path}: persisted compatibility must enter through an approved StorageMigrator caller`);
    }
  }

  if (failures.length > 0) throw new Error(`iOS Host contract failed:\n${failures.join("\n")}`);
  return `iOS Host contract ${files.length} client files`;
}

if (import.meta.main) await runCheck(check);
