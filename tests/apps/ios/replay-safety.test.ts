import { expect, test } from "bun:test";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ROOT } from "../../../tools/lib.ts";
import { qaConfig } from "../../../tools/qa/qa-config.ts";

const config = qaConfig("ox-5");
const runtime = "com.apple.CoreSimulator.SimRuntime.iOS-27-0";

// Exercise the executable, substituting only sim so failures cannot erase real QA data.
async function replay(args: string[], state = "Booted", options: { runtime?: string; device?: string } = {}) {
  const directory = await mkdtemp(join(tmpdir(), "openox-replay-e2e-"));
  const trace = join(directory, "calls.jsonl");
  const inventory = { devices: { [options.runtime ?? runtime]: state === "missing" ? [] : [
    { name: config.device, state, isAvailable: state !== "unavailable" },
  ] } };
  try {
    await writeFile(join(directory, "sim"), `#!${process.execPath}
import { appendFileSync } from "node:fs";
const args = Bun.argv.slice(2);
appendFileSync(Bun.env.REPLAY_TRACE, JSON.stringify(args) + "\\n");
if (args[0] === "devices" && args.length === 1) console.log(Bun.env.REPLAY_INVENTORY);
else if (args[2] === "run") { console.error("fixture launch failure"); process.exit(1); }
else console.log("{}");
`);
    await chmod(join(directory, "sim"), 0o755);
    const child = Bun.spawn([process.execPath, join(ROOT, "tools/qa/service-replay.ts"), ...args], {
      env: {
        ...Bun.env, PATH: `${directory}:${Bun.env.PATH}`, TMPDIR: directory,
        OX_QA_DEVICE: options.device ?? "", OX_SERVER_ROOT: "", OX_BUNDLE_ID: "ai.openox.local",
        REPLAY_TRACE: trace, REPLAY_INVENTORY: JSON.stringify(inventory),
      },
      stdout: "pipe", stderr: "pipe",
    });
    const [code, stdout, stderr] = await Promise.all([
      child.exited, new Response(child.stdout).text(), new Response(child.stderr).text(),
    ]);
    const lines = await readFile(trace, "utf8").catch(() => "");
    const calls = lines.trim() ? lines.trim().split("\n").map(line => JSON.parse(line) as string[]) : [];
    expect(await Bun.file(join(directory, "ox-qa-tests", `${config.device}.lock`)).exists()).toBe(false);
    return { code, stdout, stderr, calls };
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

const args = ["--device", config.device];
const uninstall = ["--device", config.device, "uninstall", "ai.openox.local"];
const boot = ["devices", "boot", config.device];
const shutdown = ["devices", "shutdown", config.device];

test("replay requires explicit selection and does not touch a simulator on preflight failure", async () => {
  for (const device of [undefined, config.device]) {
    const result = await replay([], "Booted", { device });
    expect(result.code).toBe(1);
    expect(result.stderr).toContain("--device ox-N");
    expect(result.calls).toEqual([]);
  }
  const server = createServer();
  try {
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(config.serviceProxyPort, "127.0.0.1", resolve);
    });
    const result = await replay(args);
    expect(result.code).toBe(1);
    expect(result.stderr).toContain(`Port ${config.serviceProxyPort} is already in use`);
    expect(result.calls).toEqual([]);
  } finally {
    await new Promise<void>(resolve => server.close(() => resolve()));
  }
});

test("replay rejects unavailable, wrong-runtime and transitioning devices without provisioning or cleanup mutations", async () => {
  for (const [state, selectedRuntime, message] of [
    ["missing", runtime, "unavailable"],
    ["unavailable", runtime, "unavailable"],
    ["Booted", "com.apple.CoreSimulator.SimRuntime.iOS-26-0", "must run iOS 27"],
    ["Booting", runtime, "wait before running QA"],
  ]) {
    const result = await replay(args, state, { runtime: selectedRuntime });
    expect(result.code).toBe(1);
    expect(result.stderr).toContain(message);
    expect(result.calls).toEqual([["devices"]]);
  }
});

test("replay preserves existing app data and boot state when launch fails; reset is opt-in", async () => {
  for (const state of ["Booted", "Shutdown"]) {
    for (const reset of [false, true]) {
      const result = await replay([...args, ...(reset ? ["--reset"] : [])], state);
      expect(result.code).toBe(1);
      expect(result.stderr).toContain("fixture launch failure");
      expect(result.calls.filter(call => call.includes("uninstall"))).toEqual(reset ? [uninstall] : []);
      expect(result.calls.filter(call => call[1] === "boot")).toEqual(state === "Shutdown" ? [boot] : []);
      expect(result.calls.filter(call => call[1] === "shutdown")).toEqual(state === "Shutdown" ? [shutdown] : []);
      expect(result.calls).toContainEqual(["--device", config.device, "logs"]);
      if (reset) {
        expect(result.calls.findIndex(call => call.includes("uninstall")))
          .toBeLessThan(result.calls.findIndex(call => call.includes("run")));
      }
    }
  }
});
