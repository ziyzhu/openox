import { cp, lstat, mkdir, mkdtemp, open, readdir, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { parseArgs } from "node:util";
import { ROOT, killChildren, run } from "../../../lib.ts";
import { iosTarget } from "./ios.ts";
import { qaConfig } from "./qa-config.ts";
import { claimSimulator, requireSimulator } from "./simulator.ts";
import { DeviceTemplateSchema, parseTemplate, prepareTemplate, relativeStoragePath } from "./template-schema.ts";

const usage = `Usage: bun run sim:launch --device ox-N --template <json> [options]
  --app <Ox.app>             Reuse a Debug Simulator artifact instead of building
  --bundle <id>              Expected bundle identifier (otherwise Local.xcconfig)
  --output <directory>       Evidence parent outside the repository
  --validate                 Validate all template inputs without touching a simulator
  --schema                   Print the JSON Schema defined in TypeScript
  --allow-keychain            Authorize declared credential writes/replacements
  --allow-storage-replay      Authorize declared raw storage replacements; retains backups
  --loopback                 Launch-only Debug localhost Host ingress; does not enable connections
  -h, --help                 Show help
Templates create run-owned Profiles, never merge into existing Profiles or erase devices.
Reserve the target with other agents before running. The app and template state remain open for inspection.`;

function inside(root: string, path: string): boolean {
  const suffix = relative(root, path);
  return !suffix || suffix !== ".." && !suffix.startsWith("../") && !isAbsolute(suffix);
}

export async function privateOutput(parent: string, prefix: string): Promise<string> {
  await mkdir(parent, { recursive: true });
  const actual = await realpath(parent);
  if (inside(await realpath(ROOT), actual)) throw new Error("Store private template evidence outside the repository");
  return mkdtemp(join(actual, prefix));
}

async function inventory(path: string): Promise<{ bytes: number; sha256: string }> {
  const hash = new Bun.CryptoHasher("sha256");
  let bytes = 0;
  let entries = 0;
  const visit = async (path: string, name: string): Promise<void> => {
    const info = await lstat(path);
    if (++entries > 100000) throw new Error("Template storage input exceeds 100,000 entries");
    if (info.isSymbolicLink()) throw new Error("Template storage inputs must not contain symbolic links");
    if (info.isFile()) {
      if (info.nlink !== 1) throw new Error("Template storage inputs must not contain hard links");
      bytes += info.size;
      if (bytes > 512 * 1024 * 1024) throw new Error("Template storage input exceeds 512 MiB");
      hash.update(JSON.stringify(["file", name, info.size]));
      const reader = Bun.file(path).stream().getReader();
      try {
        for (;;) {
          const chunk = await reader.read();
          if (chunk.done) break;
          hash.update(chunk.value);
        }
      } finally { reader.releaseLock(); }
      return;
    }
    if (!info.isDirectory()) throw new Error("Template storage input must be a file or directory");
    hash.update(JSON.stringify(["directory", name]));
    for (const child of (await readdir(path)).sort()) {
      if (child === "logs.jsonl" || child === "DeviceTemplates") throw new Error("Logs and template control files cannot be seeded");
      await visit(join(path, child), name + "/" + child);
    }
  };
  await visit(path, "");
  return { bytes, sha256: hash.digest("hex") };
}

async function safeDestination(root: string, path: string): Promise<string> {
  const destination = resolve(root, relativeStoragePath(path));
  if (!inside(root, destination)) throw new Error("Storage destination escapes its domain");
  let ancestor = destination;
  for (;;) {
    try {
      const actual = await realpath(ancestor);
      if (!inside(root, actual) || actual !== ancestor) throw new Error("Storage destination traverses a symbolic link");
      return destination;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      ancestor = dirname(ancestor);
    }
  }
}

export async function launchTemplate(args = Bun.argv.slice(2), build = true): Promise<void> {
  const { values } = parseArgs({ args, strict: true, options: {
    device: { type: "string" }, template: { type: "string" }, app: { type: "string" }, bundle: { type: "string" },
    output: { type: "string" }, validate: { type: "boolean" }, schema: { type: "boolean" }, "allow-keychain": { type: "boolean" },
    "allow-storage-replay": { type: "boolean" }, loopback: { type: "boolean" }, help: { type: "boolean", short: "h" },
  } });
  if (values.help) { console.log(usage); return; }
  if (values.schema) { console.log(JSON.stringify(DeviceTemplateSchema, null, 2)); return; }
  if (!values.template) throw new Error("Pass --template <json>");
  const source = resolve(values.template);
  if (Bun.file(source).size > 8 * 1024 * 1024) throw new Error("Template JSON exceeds 8 MiB");
  const template = parseTemplate(await Bun.file(source).json());
  const runID = crypto.randomUUID().toUpperCase();
  const prepared = await prepareTemplate(template, source, runID);
  const storage = await Promise.all((template.storage ?? []).map(async entry => {
    const input = resolve(dirname(source), entry.from);
    const inspected = await inventory(input);
    const from = await realpath(input);
    return { ...entry, from, ...inspected };
  }));
  if (storage.reduce((sum, entry) => sum + entry.bytes, 0) > 1024 * 1024 * 1024) throw new Error("Template storage inputs exceed 1 GiB");
  for (const entry of storage) {
    if (storage.some(other => other !== entry && other.domain === entry.domain && (other.path === entry.path || other.path.startsWith(entry.path + "/")))) {
      throw new Error("Template storage destinations overlap");
    }
  }
  if (values.validate) { console.log("VALID template and external inputs"); return; }
  if (!values.device) throw new Error("Pass --device ox-N explicitly after reserving the simulator");
  if (prepared.keychain && !values["allow-keychain"]) throw new Error("Credential writes require --allow-keychain");
  const rawPreferences = ["storage.activeProfile", "secret.index"].some(key => key in (template.userDefaults?.app?.set ?? {}) || template.userDefaults?.app?.remove?.includes(key));
  if ((storage.length || rawPreferences) && !values["allow-storage-replay"]) throw new Error("Raw storage or identity/credential metadata replacement requires --allow-storage-replay");
  const config = qaConfig(values.device);
  if (!Bun.which("idb")) throw new Error("Install idb before launching templates");
  const ios = iosTarget(config.device);
  const localConfig = await Bun.file(join(ROOT, "apps/ios/Local.xcconfig")).text().catch(() => "");
  const bundle = values.bundle ?? Bun.env.OX_BUNDLE_ID ?? /^OX_BUNDLE_IDENTIFIER\s*=\s*([^\s/]+)/m.exec(localConfig)?.[1];
  if (!bundle) throw new Error("Configure Local.xcconfig or pass --bundle");
  const release = claimSimulator(config.device);
  let interrupted: NodeJS.Signals | undefined;
  const interrupt = (signal: NodeJS.Signals) => { interrupted = signal; killChildren(signal); };
  process.on("SIGINT", interrupt);
  process.on("SIGTERM", interrupt);
  let evidence: string | undefined;
  let control: string | undefined;
  let launched = false;
  let manifest: Record<string, unknown> = {};
  try {
    const booted = await requireSimulator(config.device);
    evidence = await privateOutput(resolve(values.output ?? tmpdir()), "openox-template-");
    manifest = { runID, device: config.device, udid: await ios.udid(), bundle, templateSHA256: new Bun.CryptoHasher("sha256").update(await Bun.file(source).arrayBuffer()).digest("hex"), status: "preparing", storage: [] };
    console.log(`Template ${config.device}; evidence: ${evidence}`);
    if (!booted) await ios.boot();
    const app = values.app ? resolve(values.app) : build
      ? await ios.build(join(evidence, "DerivedData"), join(evidence, "build.log"))
      : (await run(["xcrun", "simctl", "get_app_container", await ios.udid(), bundle, "app"], { capture: true })).stdout.trim();
    const plist = async (key: string) => (await run(["plutil", "-extract", key, "raw", "-o", "-", join(app, "Info.plist")], { capture: true })).stdout.trim();
    if (await plist("CFBundleIdentifier") !== bundle || await plist("DTPlatformName") !== "iphonesimulator") throw new Error("Use a matching Simulator app artifact");
    const name = await plist("CFBundleExecutable");
    const binary = Bun.file(join(app, `${name}.debug.dylib`));
    const executable = await (await binary.exists() ? binary : Bun.file(join(app, name))).arrayBuffer();
    if (!Buffer.from(executable).includes(Buffer.from("OX_DEVICE_TEMPLATE"))) throw new Error("This artifact does not support Debug Simulator templates; rebuild this checkout");
    manifest.build = { version: await plist("CFBundleShortVersionString"), build: await plist("CFBundleVersion") };
    const groupID = await plist("OXAppGroupIdentifier");
    if (interrupted) throw new Error(`Interrupted by ${interrupted}`);
    if (values.app || build) await run(["xcrun", "simctl", "install", await ios.udid(), app], { capture: true });
    await run(["xcrun", "simctl", "terminate", await ios.udid(), bundle], { capture: true, allowFailure: true });
    const processes = await run(["xcrun", "simctl", "spawn", await ios.udid(), "launchctl", "list"], { capture: true });
    if (processes.stdout.split("\n").some(line => /^\d+\s/.test(line) && line.includes(`UIKitApplication:${bundle}[`))) throw new Error("Ox is still running; refusing storage replacement");
    const appRoot = await realpath(await ios.containerPath(bundle, "."));
    const groupRoot = storage.some(entry => entry.domain === "appGroup")
      ? await realpath((await run(["xcrun", "simctl", "get_app_container", await ios.udid(), bundle, groupID], { capture: true })).stdout.trim()) : undefined;
    const destinations = await Promise.all(storage.map(async entry => {
      const root = entry.domain === "appGroup" ? groupRoot! : join(appRoot, { documents: "Documents", applicationSupport: "Library/Application Support", caches: "Library/Caches" }[entry.domain]);
      await mkdir(root, { recursive: true });
      return { ...entry, destination: await safeDestination(await realpath(root), entry.path) };
    }));
    if (destinations.some(destination => storage.some(source => inside(destination.destination, source.from) || inside(source.from, destination.destination)))) throw new Error("Snapshot sources overlap storage destinations; capture a separate stopped-process copy first");
    for (const [index, entry] of destinations.entries()) {
      const backup = join(evidence, "storage-backups", String(index));
      let exists = true;
      try { await lstat(entry.destination); } catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") exists = false; else throw error; }
      if (exists) { await mkdir(dirname(backup), { recursive: true }); await cp(entry.destination, backup, { recursive: true, errorOnExist: true, force: false }); }
      (manifest.storage as unknown[]).push({ domain: entry.domain, path: entry.path, provenance: entry.provenance, sha256: entry.sha256, bytes: entry.bytes, backup: exists ? backup : null });
      await writeFile(join(evidence, "manifest.json"), JSON.stringify(manifest, null, 2), { mode: 0o600 });
      if (exists) await rm(entry.destination, { recursive: true });
      await mkdir(dirname(entry.destination), { recursive: true });
      await cp(entry.from, entry.destination, { recursive: true, errorOnExist: true, force: false });
      if ((await inventory(entry.destination)).sha256 !== entry.sha256) throw new Error("Restored storage differs from the preflight snapshot; retained backup is available");
    }
    control = await ios.containerPath(bundle, `Library/Caches/DeviceTemplates/${runID}`);
    await mkdir(control, { recursive: true, mode: 0o700 });
    const descriptor = await open(join(control, "input.json"), "wx", 0o600);
    try { await descriptor.writeFile(JSON.stringify(prepared)); } finally { await descriptor.close(); }
    await run(["xcrun", "simctl", "launch", "--terminate-running-process", await ios.udid(), bundle], {
      capture: true, env: { SIMCTL_CHILD_OX_DEVICE_TEMPLATE: runID, SIMCTL_CHILD_OX_DEBUG_ENDPOINT: config.debugEndpoint, SIMCTL_CHILD_OX_HOST_LOOPBACK: values.loopback ? "1" : "0" },
    });
    launched = true;
    const deadline = Date.now() + 60_000;
    let result: { status: string; error?: string; profiles: Record<string, string>; conversations: Record<string, Record<string, string>> } | undefined;
    while (Date.now() < deadline) {
      if (interrupted) throw new Error(`Interrupted by ${interrupted}`);
      const output = Bun.file(join(control, "result.json"));
      if (await output.exists()) { result = await output.json(); break; }
      await Bun.sleep(200);
    }
    if (!result || result.status !== "applied") {
      if (result) manifest.result = result;
      throw new Error(result?.error ?? "Template readiness timed out; inspect evidence logs");
    }
    manifest.result = result;
    manifest.status = "applied";
    if (template.settings?.onboardingCompleted === true || template.selection?.conversation) await ios.wait({ id: "conversation.openSidebar" }, { timeout: 15000 });
    await writeFile(join(evidence, "accessibility.json"), JSON.stringify(await ios.describe()), { mode: 0o600 });
    await ios.screenshot(join(evidence, "ready.png"));
    console.log(`APPLIED ${config.device}; run ${runID}`);
  } catch (error) {
    manifest.status = "failed";
    throw error;
  } finally {
    try {
      if (control) {
        await rm(join(control, "input.json"), { force: true });
        const previous = join(control, "preferences-before.plist");
        if (evidence && await Bun.file(previous).exists()) await cp(previous, join(evidence, "preferences-before.plist"));
      }
      if (evidence) {
        await writeFile(join(evidence, "manifest.json"), JSON.stringify(manifest, null, 2), { mode: 0o600 });
        if (launched) {
          if (manifest.status === "failed") {
            try {
              await writeFile(join(evidence, "failure-accessibility.json"), JSON.stringify(await ios.describe()), { mode: 0o600 });
              await ios.screenshot(join(evidence, "failure.png"));
            } catch {}
          }
          const logs = await ios.logs();
          await writeFile(join(evidence, "logs.ndjson"), logs.stdout + logs.stderr, { mode: 0o600 });
        }
      }
    } finally {
      process.off("SIGINT", interrupt);
      process.off("SIGTERM", interrupt);
      release();
    }
  }
}

if (import.meta.main) {
  try { await launchTemplate(); }
  catch (error) { console.error(`error: ${(error as Error).message}`); process.exitCode = 1; }
}
