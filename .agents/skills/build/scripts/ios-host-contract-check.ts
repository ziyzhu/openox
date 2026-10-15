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

const topLevelDeclaration = /^(?:(?:public|private|fileprivate|internal|nonisolated|final|@MainActor|@Observable)\s+)*(?:struct|enum|class|actor|protocol|typealias)\s+([A-Z]\w*)/gm;

async function uiBoundaryFailures(): Promise<string[]> {
  const appRoots = ["apps/shared/Host", "apps/ios/Host", "apps/ios/Client/Features", "apps/ios/Client/App"].map(path => join(ROOT, path));
  const appFiles = [...(await Promise.all(appRoots.map(swiftFiles))).flat(), join(ROOT, "apps/ios/Client/OxClient.swift")];
  const appTypes = new Set<string>();
  for (const file of appFiles) {
    for (const match of (await readFile(file, "utf8")).matchAll(topLevelDeclaration)) appTypes.add(match[1]);
  }
  const failures: string[] = [];
  for (const file of await swiftFiles(join(ROOT, "apps/ios/Client/UI"))) {
    const code = (await readFile(file, "utf8")).replace(/\/\/.*$/gm, "").replace(/"(?:\\.|[^"\\\n])*"/g, '""');
    const references = new Set([...code.matchAll(/\b[A-Z]\w*\b/g)].map(match => match[0]).filter(name => appTypes.has(name)));
    for (const name of references) failures.push(`${relative(ROOT, file)}: UI must not reference app type ${name}`);
  }
  return failures;
}

export async function check(): Promise<string> {
  const clientRoots = [
    join(ROOT, "apps/ios/Client/Features"),
    join(ROOT, "apps/ios/Client/UI"),
  ];
  const files = (await Promise.all(clientRoots.map(swiftFiles))).flat();
  const failures: string[] = [];

  for (const file of files) {
    const source = await readFile(file, "utf8");
    if (file !== join(ROOT, "apps/ios/Client/UI/Searchable.swift") && /\.searchable\s*\(/.test(source)) {
      failures.push(`${relative(ROOT, file)}: use oxSearchable so the native search field has an automation identifier`);
    }
    for (const forbidden of ["IOSHost", "OxHost", "OxRuntime"]) {
      if (source.includes(forbidden)) {
        failures.push(`${relative(ROOT, file)}: client layer references ${forbidden}`);
      }
    }
  }

  failures.push(...await uiBoundaryFailures());

  const hostContract = await readFile(join(ROOT, "apps/shared/Host/OxHost.swift"), "utf8");
  if (!hostContract.includes("protocol OxHost: AnyObject")) {
    failures.push("apps/shared/Host/OxHost.swift: missing OxHost contract");
  }

  const host = await readFile(join(ROOT, "apps/ios/Host/IOSHost.swift"), "utf8");
  if (!host.includes("final class IOSHost: OxHost")) {
    failures.push("apps/ios/Host/IOSHost.swift: IOSHost must implement OxHost");
  }
  const runtime = await readFile(join(ROOT, "apps/shared/Host/HostRuntime.swift"), "utf8");
  if (!host.includes("HostRuntime(") || !host.includes("try await runtime.prepare()") || !runtime.includes("StorageMigrator.prepare")) {
    failures.push("Host preparation must pass through HostRuntime and StorageMigrator");
  }
  for (const forbidden of ["import UIKit", "UIApplication", "ScheduledSkillScheduler.shared"]) {
    if (runtime.includes(forbidden)) failures.push(`HostRuntime must not own iOS policy (${forbidden})`);
  }

  const client = await readFile(join(ROOT, "apps/ios/Client/OxClient.swift"), "utf8");
  if (!client.includes("private let host: any OxHost")) {
    failures.push("apps/ios/Client/OxClient.swift: OxClient must target the OxHost contract");
  }

  const app = await readFile(join(ROOT, "apps/ios/Client/App/App.swift"), "utf8");
  if (!app.includes("OxClient(host: host)") || !app.includes("WebSocketOxHostTransport(host: host, access: access)")) {
    failures.push("apps/ios/Client/App/App.swift: composition root must connect in-process and WebSocket transports to one Host");
  }

  const hostProtocol = await readFile(join(ROOT, "apps/ios/Host/OxHostProtocol.swift"), "utf8");
  if (!hostProtocol.includes("host: any OxHost")) {
    failures.push("apps/ios/Host/OxHostProtocol.swift: Host protocol must target the OxHost contract");
  }
  for (const forbidden of ["viewportController", "ConversationComposerModel", "var setEditDraft"]) {
    if (hostProtocol.includes(forbidden)) {
      failures.push(`apps/ios/Host/OxHostProtocol.swift: UI automation state must remain in ClientAutomation (${forbidden})`);
    }
  }

  const webSocketTransport = await readFile(
    join(ROOT, "apps/shared/Host/WebSocketOxHostTransport.swift"),
    "utf8",
  );
  if (!webSocketTransport.includes("OxHostProtocol.handle(data, host: self.host, admit:")) {
    failures.push("apps/shared/Host/WebSocketOxHostTransport.swift: WebSocket transport must dispatch through OxHostProtocol");
  }
  for (const path of [
    "apps/shared/Host/WebSocketOxHostTransport.swift",
    "apps/ios/Host/OxHostRPC.swift",
    "apps/ios/Host/OxHostProtocol.swift",
    "apps/shared/Host/OxHostProtocolMessages.swift",
    "apps/shared/Host/RPC/HostRPCRequests.swift",
    "apps/shared/Host/Profile/StorageRoot.swift",
    "apps/shared/Host/Services/ServiceDebug.swift",
    "apps/shared/Host/Profile/ProfileRepositorySaveGate.swift",
    ...["ConversationCommands", "ServiceCommands", "BootstrapCommands"].map(name => `apps/shared/Host/RPC/${name}.swift`),
    ...["ComposerCommands", "ClientAutomation"].map(name => `apps/ios/Client/Automation/${name}.swift`),
  ]) {
    const source = await readFile(join(ROOT, path), "utf8");
    if (source.includes("#if targetEnvironment(simulator)") || source.includes("#if DEBUG")) {
      failures.push(`${path}: Client–Host capabilities must not depend on build or Simulator`);
    }
  }
  for (const required of ["ingress.constrain(parameters)", "parameters.requiredLocalEndpoint = .hostPort", "HostTransportIngress.current(on:", "pathUpdateHandler", "self.hasCurrentIngress(client)"]) {
    if (!webSocketTransport.includes(required)) failures.push(`WebSocket transport must enforce its selected ingress (${required})`);
  }
  if (/\.loopback\b/.test(webSocketTransport) || webSocketTransport.includes("NWListener(using: parameters, on:")) {
    failures.push("WebSocket transport must not select loopback directly or expose an unrestricted listener");
  }
  const transportIngress = await readFile(join(ROOT, "apps/ios/Host/HostTransportIngress.swift"), "utf8");
  for (const required of ["#if DEBUG && targetEnvironment(simulator)", 'environment["OX_HOST_LOOPBACK"] == "1"', "parameters.requiredInterface = ingress.interface", "parameters.requiredInterfaceType = .loopback", "TailscaleHostIngress.current(on:", 'address == "127.0.0.1"', "remoteHost == NWEndpoint.Host(address)"]) {
    if (!transportIngress.includes(required)) failures.push(`Host ingress must constrain its opt-in Debug loopback (${required})`);
  }
  const productionIngress = transportIngress.replace(/#if DEBUG && targetEnvironment\(simulator\)[\s\S]*?#endif/g, "");
  if ([".loopback", '"127.0.0.1"', '"OX_HOST_LOOPBACK"'].some(value => productionIngress.includes(value))) {
    failures.push("Host loopback must be compiled out of Release and physical-device builds");
  }
  if (app.includes("WebSocketOxHostTransport.configuredPort != nil")) {
    failures.push("Foreground Host access must not require launch configuration");
  }
  if (!webSocketTransport.includes("access.enabled && host.state == .running && host.executionAvailable") || !webSocketTransport.includes("if available { start() } else if monitor != nil { stop() }") || !webSocketTransport.includes("access.onEnabledChange")) {
    failures.push("Host access must be opt-in and stop immediately when disabled");
  }
  const ingress = await readFile(join(ROOT, "apps/shared/Host/TailscaleHostIngress.swift"), "utf8");
  for (const required of ["interface.type == .other", "ipv4.count == 1, ipv6.count == 1", "candidates.count == 1", "path.availableInterfaces.allSatisfy({ $0.index == interface.index })"]) {
    if (!ingress.includes(required)) failures.push(`Tailscale ingress must fail closed (${required})`);
  }
  if (ingress.includes("#if DEBUG") || ingress.includes("#if targetEnvironment(simulator)")) {
    failures.push("Tailscale ingress must not depend on build or Simulator");
  }
  if (webSocketTransport.includes("onCommand")) {
    failures.push("apps/shared/Host/WebSocketOxHostTransport.swift: transport must bind directly to its Host");
  }

  const allSwiftFiles = (await Promise.all(["apps/ios", "apps/shared"].map(path => swiftFiles(join(ROOT, path))))).flat();
  const allSource = await Promise.all(allSwiftFiles.map((file) => readFile(file, "utf8")));
  if (allSource.some((source) => source.includes("DebugServer") || source.includes("OxHostAPI"))) {
    failures.push("apps/ios: legacy DebugServer or OxHostAPI reference remains");
  }

  const migrationOwners = ["StorageMigrator", "ProfileMigrator", "ApplicationStorageMigrator", "CredentialMigrator", "RepositoryMigrator", "StorageMigrationSupport", "ConversationMigrator"];
  const migrationFiles = [
    ...["StorageMigration", ...migrationOwners.slice(1, -1)].map(name => `apps/shared/Host/Profile/${name}.swift`),
    "apps/shared/Host/Conversations/ConversationMigrator.swift",
    "apps/shared/Host/Conversations/ConversationMigrator+Durable.swift",
  ];
  const migrationCallers: Record<string, Set<string>> = {
    StorageMigrator: new Set([migrationFiles[0], "apps/ios/Host/IOSHost.swift", "apps/shared/Host/HostRuntime.swift"]),
    ProfileMigrator: new Set([...migrationFiles, "apps/shared/Host/Profile/ProfileRepository.swift", "apps/shared/Host/Profile/StorageRoot.swift", "apps/shared/Host/Durable/DurableProfileStore.swift", "apps/shared/Host/RPC/DebugDurableConversation.swift"]),
    ApplicationStorageMigrator: new Set([...migrationFiles, "apps/shared/Host/Profile/ScheduledSkills.swift"]),
    CredentialMigrator: new Set(migrationFiles),
    RepositoryMigrator: new Set([...migrationFiles, "apps/shared/Host/Services/Repository/Repository.swift"]),
    StorageMigrationSupport: new Set(migrationFiles),
    ConversationMigrator: new Set([...migrationFiles, "apps/shared/Host/Durable/DurableFileStore.swift"]),
  };
  for (const [index, source] of allSource.entries()) {
    const path = relative(ROOT, allSwiftFiles[index]);
    for (const owner of migrationOwners) {
      const calls = [...source.matchAll(new RegExp(`\\b${owner}\\.([a-zA-Z0-9_]+)\\s*\\(`, "g"))];
      const readOnlySkillCompatibility = owner === "ProfileMigrator"
        && path === "apps/shared/Host/Profile/VirtualFileSystem.swift"
        && calls.every(match => match[1] === "legacyWorkflowLocation");
      if (calls.length && !migrationCallers[owner].has(path) && !readOnlySkillCompatibility) {
        failures.push(`${path}: persisted compatibility must enter through an approved ${owner} caller`);
      }
    }
  }

  if (failures.length > 0) throw new Error(`iOS Host contract failed:\n${failures.join("\n")}`);
  return `iOS Host contract ${files.length} client files`;
}

if (import.meta.main) await runCheck(check);
