import { cp, mkdir, realpath, stat } from "node:fs/promises";
import { basename, dirname, join, relative, resolve, isAbsolute } from "node:path";
import { run } from "../../../lib.ts";
import { resolveSimulator } from "./simulator.ts";

export type Element = { AXUniqueId?: string; AXLabel?: string; AXValue?: string; frame?: { x: number; y: number; width: number; height: number }; [key: string]: unknown };
type Selector = { id?: string; label?: string };
type WaitOptions = { timeout?: number; stable?: number; missing?: boolean };

export function elements(value: unknown): Element[] {
  if (Array.isArray(value)) return value.flatMap(elements);
  if (value && typeof value === "object") return [value as Element, ...Object.values(value).flatMap(elements)];
  return [];
}

export function iosTarget(device: string) {
  let target: ReturnType<typeof resolveSimulator> | undefined;
  const udid = async () => (await (target ??= resolveSimulator(device))).udid;
  const simctl = async (...args: string[]) => run(["xcrun", "simctl", ...args], { capture: true });
  const describe = async () => {
    const result = await run(["idb", "ui", "describe-all", "--udid", await udid()], { capture: true });
    return { accessibility: JSON.parse(result.stdout) };
  };
  const wait = async (selector: Selector, options: WaitOptions = {}) => {
    const deadline = Date.now() + (options.timeout ?? 10_000);
    let signature: string | undefined, since = 0;
    while (Date.now() < deadline) {
      const matches = elements(await describe()).filter(element => selector.id
        ? element.AXUniqueId === selector.id : element.AXLabel?.includes(selector.label ?? ""));
      const match = matches.find(element => element.frame && element.frame.width > 0 && element.frame.height > 0);
      const ready = options.missing ? matches.length === 0 : !!match;
      const next = ready ? JSON.stringify(match?.frame ?? "missing") : undefined;
      if (next !== signature) { signature = next; since = Date.now(); }
      if (ready && Date.now() - since >= (options.stable ?? 0)) return match;
      await Bun.sleep(100);
    }
    throw new Error(`${device}: timed out waiting for ${JSON.stringify({ ...selector, ...options })}`);
  };
  const containerPath = async (bundle: string, path: string) => {
    const root = await realpath((await simctl("get_app_container", await udid(), bundle, "data")).stdout.trim());
    const destination = resolve(root, path);
    const inside = (candidate: string) => {
      const fromRoot = relative(root, candidate);
      return fromRoot !== ".." && !fromRoot.startsWith("../") && !isAbsolute(fromRoot);
    };
    if (!inside(destination)) throw new Error(`Path escapes app container: ${path}`);
    let ancestor = destination;
    for (;;) {
      try {
        if (!inside(await realpath(ancestor))) throw new Error(`Symlink escapes app container: ${path}`);
        break;
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
        ancestor = dirname(ancestor);
      }
    }
    return destination;
  };
  const launch = async (bundle: string, app: string, env: Record<string, string> = {}) => {
    await simctl("install", await udid(), app);
    const result = await run(["xcrun", "simctl", "launch", "--terminate-running-process", await udid(), bundle], {
      capture: true, env: Object.fromEntries(Object.entries(env).map(([key, value]) => [`SIMCTL_CHILD_${key}`, value])),
    });
    return { udid: await udid(), output: result.stdout };
  };
  return {
    udid, describe, wait, containerPath, launch,
    async boot() {
      await simctl("boot", await udid());
      await simctl("bootstatus", await udid(), "-b");
    },
    async shutdown() { await simctl("shutdown", await udid()); },
    async tap(selector: Selector, options: WaitOptions & { duration?: number } = {}) {
      const match = await wait(selector, { ...options, missing: false });
      const frame = match!.frame!;
      const point = [String(Math.round(frame.x + frame.width / 2)), String(Math.round(frame.y + frame.height / 2))];
      const hit = await run(["idb", "ui", "describe-point", ...point, "--udid", await udid()], { capture: true });
      const reachable = elements(JSON.parse(hit.stdout)).some(element => selector.id
        ? element.AXUniqueId === selector.id : element.AXLabel?.includes(selector.label ?? ""));
      if (!reachable) throw new Error(`${device}: tap target is obscured or moved: ${JSON.stringify(selector)}`);
      await run(["idb", "ui", "tap", ...point,
        ...(options.duration ? ["--duration", String(options.duration)] : []), "--udid", await udid()], { capture: true });
    },
    async text(value: string) { await run(["idb", "ui", "text", value, "--udid", await udid()], { capture: true }); },
    async screenshot(path: string) { await run(["idb", "screenshot", path, "--udid", await udid()], { capture: true }); },
    async pull(bundle: string, path: string, destination: string) {
      const source = await containerPath(bundle, path);
      await mkdir(destination, { recursive: true });
      const output = (await stat(source)).isDirectory() ? destination : join(destination, basename(source));
      await cp(source, output, { recursive: true, force: true });
      return output;
    },
    async defaults(bundle: string, key: string) {
      return run(["xcrun", "simctl", "spawn", await udid(), "defaults", "read", bundle, key], { capture: true, allowFailure: true });
    },
    async logs() {
      return run(["xcrun", "simctl", "spawn", await udid(), "log", "show", "--last", "5m", "--style", "ndjson",
        "--predicate", 'process == "Ox"'], { capture: true, allowFailure: true });
    },
    async build(derivedData: string, log: string) {
      const result = await run(["xcodebuild", "-project", "apps/ios/Ox.xcodeproj", "-scheme", "ios", "-configuration", "Debug",
        "-destination", `platform=iOS Simulator,id=${await udid()}`, "-derivedDataPath", derivedData, "build"], { capture: true, allowFailure: true });
      await Bun.write(log, result.stdout + result.stderr);
      if (result.code) throw new Error(`xcodebuild failed (${result.code}); see ${log}: ${(result.stderr || result.stdout).slice(-4000)}`);
      return join(derivedData, "Build/Products/Debug-iphonesimulator/Ox.app");
    },
  };
}
