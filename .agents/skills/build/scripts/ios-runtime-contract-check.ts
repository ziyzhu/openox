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
  const appRoots = ["apps/shared/Runtime", "apps/ios/Runtime", "apps/ios/Client/Features", "apps/ios/Client/App"].map(path => join(ROOT, path));
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
    for (const forbidden of ["IOSProfileRuntime", "ProfileRuntime", "OxRuntime"]) {
      if (source.includes(forbidden)) {
        failures.push(`${relative(ROOT, file)}: client layer references ${forbidden}`);
      }
    }
  }

  failures.push(...await uiBoundaryFailures());

  const hostContract = await readFile(join(ROOT, "apps/shared/Runtime/ProfileRuntime.swift"), "utf8");
  if (!hostContract.includes("protocol ProfileRuntime: AnyObject")) {
    failures.push("apps/shared/Runtime/ProfileRuntime.swift: missing ProfileRuntime contract");
  }

  const host = await readFile(join(ROOT, "apps/ios/Runtime/IOSProfileRuntime.swift"), "utf8");
  if (!host.includes("final class IOSProfileRuntime: ProfileRuntime")) {
    failures.push("apps/ios/Runtime/IOSProfileRuntime.swift: IOSProfileRuntime must implement ProfileRuntime");
  }
  const runtime = await readFile(join(ROOT, "apps/shared/Runtime/SharedProfileRuntime.swift"), "utf8");
  if (!host.includes("SharedProfileRuntime(") || !host.includes("try await runtime.prepare()") || !runtime.includes("StorageMigrator.prepare")) {
    failures.push("Runtime preparation must pass through SharedProfileRuntime and StorageMigrator");
  }
  for (const forbidden of ["import UIKit", "UIApplication", "ScheduledSkillScheduler.shared"]) {
    if (runtime.includes(forbidden)) failures.push(`SharedProfileRuntime must not own iOS policy (${forbidden})`);
  }

  const client = await readFile(join(ROOT, "apps/ios/Client/OxClient.swift"), "utf8");
  if (!client.includes("private let runtime: any ProfileRuntime")) {
    failures.push("apps/ios/Client/OxClient.swift: OxClient must target the ProfileRuntime contract");
  }

  const app = await readFile(join(ROOT, "apps/ios/Client/App/App.swift"), "utf8");
  if (!app.includes("OxClient(runtime: runtime)") || !app.includes("ProfileServer(runtime: runtime, access: access)")) {
    failures.push("apps/ios/Client/App/App.swift: composition root must connect in-process and WebSocket transports to one runtime");
  }

  const hostProtocol = await readFile(join(ROOT, "apps/ios/Runtime/ProfileProtocol.swift"), "utf8");
  if (!hostProtocol.includes("runtime: any ProfileRuntime")) {
    failures.push("apps/ios/Runtime/ProfileProtocol.swift: Profile protocol must target the ProfileRuntime contract");
  }
  for (const forbidden of ["viewportController", "ConversationComposerModel", "var setEditDraft"]) {
    if (hostProtocol.includes(forbidden)) {
      failures.push(`apps/ios/Runtime/ProfileProtocol.swift: UI automation state must remain in ClientAutomation (${forbidden})`);
    }
  }

  const webSocketTransport = await readFile(
    join(ROOT, "apps/shared/Runtime/ProfileServer.swift"),
    "utf8",
  );
  if (!webSocketTransport.includes("ProfileProtocol.handle(data, runtime: self.runtime, admit:")) {
    failures.push("apps/shared/Runtime/ProfileServer.swift: WebSocket transport must dispatch through ProfileProtocol");
  }
  for (const path of [
    "apps/shared/Runtime/ProfileServer.swift",
    "apps/ios/Runtime/ProfileRPC.swift",
    "apps/ios/Runtime/ProfileProtocol.swift",
    "apps/shared/Runtime/ProfileProtocolMessages.swift",
    "apps/shared/Runtime/RPC/ProfileRPCRequests.swift",
    "apps/shared/Runtime/Storage/StorageRoot.swift",
    "apps/shared/Runtime/Services/ServiceDebug.swift",
    "apps/shared/Runtime/Profile/ProfileRepositorySaveGate.swift",
    ...["ConversationCommands", "ServiceCommands", "BootstrapCommands"].map(name => `apps/shared/Runtime/RPC/${name}.swift`),
    ...["ComposerCommands", "ClientAutomation"].map(name => `apps/ios/Client/Automation/${name}.swift`),
  ]) {
    const source = await readFile(join(ROOT, path), "utf8");
    if (source.includes("#if targetEnvironment(simulator)") || source.includes("#if DEBUG")) {
      failures.push(`${path}: Client–runtime capabilities must not depend on build or Simulator`);
    }
  }
  for (const required of ["ingress.constrain(parameters)", "parameters.requiredLocalEndpoint = .hostPort", "ServerIngress.current(on:", "pathUpdateHandler", "self.hasCurrentIngress(client)"]) {
    if (!webSocketTransport.includes(required)) failures.push(`WebSocket transport must enforce its selected ingress (${required})`);
  }
  if (/\.loopback\b/.test(webSocketTransport) || webSocketTransport.includes("NWListener(using: parameters, on:")) {
    failures.push("WebSocket transport must not select loopback directly or expose an unrestricted listener");
  }
  const transportIngress = await readFile(join(ROOT, "apps/ios/Runtime/ServerIngress.swift"), "utf8");
  for (const required of ["#if DEBUG && targetEnvironment(simulator)", 'environment["OX_PROFILE_LOOPBACK"] == "1"', "parameters.requiredInterface = ingress.interface", "parameters.requiredInterfaceType = .loopback", "TailscaleIngress.current(on:", 'address == "127.0.0.1"', "remoteHost == NWEndpoint.Host(address)"]) {
    if (!transportIngress.includes(required)) failures.push(`Server ingress must constrain its opt-in Debug loopback (${required})`);
  }
  const productionIngress = transportIngress.replace(/#if DEBUG && targetEnvironment\(simulator\)[\s\S]*?#endif/g, "");
  if ([".loopback", '"127.0.0.1"', '"OX_PROFILE_LOOPBACK"'].some(value => productionIngress.includes(value))) {
    failures.push("Debug loopback must be compiled out of Release and physical-device builds");
  }
  if (app.includes("ProfileServer.configuredPort != nil")) {
    failures.push("Foreground connections must not require launch configuration");
  }
  if (!webSocketTransport.includes("access.allowsConnections && runtime.state == .running && runtime.executionAvailable") || !webSocketTransport.includes("if available { start() } else if monitor != nil { stop() }") || !webSocketTransport.includes("access.onChange")) {
    failures.push("Allow Connections must be opt-in and stop immediately when disabled");
  }
  const ingress = await readFile(join(ROOT, "apps/shared/Runtime/TailscaleIngress.swift"), "utf8");
  for (const required of ["interface.type == .other", "ipv4.count == 1, ipv6.count == 1", "candidates.count == 1", "path.availableInterfaces.allSatisfy({ $0.index == interface.index })"]) {
    if (!ingress.includes(required)) failures.push(`Tailscale ingress must fail closed (${required})`);
  }
  if (ingress.includes("#if DEBUG") || ingress.includes("#if targetEnvironment(simulator)")) {
    failures.push("Tailscale ingress must not depend on build or Simulator");
  }
  if (webSocketTransport.includes("onCommand")) {
    failures.push("apps/shared/Runtime/ProfileServer.swift: server must bind directly to its runtime");
  }

  const allSwiftFiles = (await Promise.all(["apps/ios", "apps/shared"].map(path => swiftFiles(join(ROOT, path))))).flat();
  const allSource = await Promise.all(allSwiftFiles.map((file) => readFile(file, "utf8")));
  if (allSource.some((source) => source.includes("DebugServer") || source.includes("OxHostAPI"))) {
    failures.push("apps/ios: legacy DebugServer or OxHostAPI reference remains");
  }

  const migrationOwners = ["StorageMigrator", "ProfileMigrator", "ApplicationStorageMigrator", "CredentialMigrator", "RepositoryMigrator", "StorageMigrationSupport", "ConversationMigrator"];
  const migrationFile = new RegExp(`^apps/shared/Runtime/Storage/(StorageMigration|${migrationOwners.slice(1).join("|")})(\\+\\w+)?\\.swift$`);
  const migrationFiles = allSwiftFiles.map(file => relative(ROOT, file)).filter(path => migrationFile.test(path));
  const migrationCallers: Record<string, Set<string>> = {
    StorageMigrator: new Set(["apps/shared/Runtime/Storage/StorageMigration.swift", "apps/ios/Runtime/IOSProfileRuntime.swift", "apps/shared/Runtime/SharedProfileRuntime.swift"]),
    ProfileMigrator: new Set([...migrationFiles, "apps/shared/Runtime/Profile/ProfileRepository.swift", "apps/shared/Runtime/Storage/StorageRoot.swift", "apps/shared/Runtime/Durable/DurableProfileStore.swift", "apps/shared/Runtime/RPC/DebugDurableConversation.swift", "apps/shared/Runtime/Schedules/Schedules.swift"]),
    ApplicationStorageMigrator: new Set(migrationFiles),
    CredentialMigrator: new Set(migrationFiles),
    RepositoryMigrator: new Set([...migrationFiles, "apps/shared/Runtime/Services/Repository/Repository.swift"]),
    StorageMigrationSupport: new Set(migrationFiles),
    ConversationMigrator: new Set([...migrationFiles, "apps/shared/Runtime/Durable/DurableFileStore.swift"]),
  };
  const scopedCompatibility: Record<string, string> = {
    "StorageMigrator apps/ios/Client/App/App.swift": "migrateApp",
    "StorageMigrator apps/ios/Development/DeviceTemplate.swift": "migrateApp",
    "ProfileMigrator apps/shared/Runtime/Files/VirtualFileSystem.swift": "legacyWorkflowLocation",
    "ConversationMigrator apps/shared/Runtime/Conversations/ConversationServiceAttachments.swift": "migratedServiceDomains",
    "ConversationMigrator apps/shared/Runtime/Conversations/ConversationDocument.swift": "isRenameAction",
  };
  for (const [index, source] of allSource.entries()) {
    const path = relative(ROOT, allSwiftFiles[index]);
    for (const owner of migrationOwners) {
      const calls = [...source.matchAll(new RegExp(`\\b${owner}\\.([a-zA-Z0-9_]+)\\s*\\(`, "g"))];
      const scoped = calls.every(match => scopedCompatibility[`${owner} ${path}`] === match[1]);
      if (calls.length && !migrationCallers[owner].has(path) && !scoped) {
        failures.push(`${path}: persisted compatibility must enter through an approved ${owner} caller`);
      }
    }
  }

  if (failures.length > 0) throw new Error(`iOS runtime contract failed:\n${failures.join("\n")}`);
  return `iOS runtime contract ${files.length} client files`;
}

if (import.meta.main) await runCheck(check);
