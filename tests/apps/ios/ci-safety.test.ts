import { expect, test } from "bun:test";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ROOT } from "../../../tools/lib.ts";

async function ios(args: string[], state = "Booted", launchFails = false) {
  const directory = await mkdtemp(join(tmpdir(), "openox-ios-ci-e2e-"));
  const trace = join(directory, "calls.jsonl");
  try {
    await writeFile(join(directory, "sim"), `#!${process.execPath}
import { appendFileSync } from "node:fs";
const args = Bun.argv.slice(2);
appendFileSync(Bun.env.IOS_TRACE, JSON.stringify(args) + "\\n");
if (args[0] === "devices" && args.length === 1) console.log(Bun.env.IOS_INVENTORY);
else if (args[2] === "run" && Bun.env.IOS_LAUNCH_FAIL === "true") { console.error("fixture build failed"); process.exit(1); }
else console.log("{}");
`);
    await chmod(join(directory, "sim"), 0o755);
    await writeFile(join(directory, "bun"), `#!${process.execPath}
import { appendFileSync } from "node:fs";
const args = Bun.argv.slice(2);
if (args[0] !== "apps/cli/src/ox.ts") {
  const child = Bun.spawn([process.execPath, ...args], { stdout: "inherit", stderr: "inherit" });
  process.exit(await child.exited);
}
appendFileSync(Bun.env.IOS_TRACE, JSON.stringify(["ox", ...args.slice(1)]) + "\\n");
const command = args[args.indexOf("chat") + 1];
const text = "Sorry that took a moment.";
const snapshot = { id: "fixture-chat", model: { id: "mock" }, isBusy: false, messages: [{ content: text }] };
const result = command === "list" ? [] : command === "new" ? { chatId: "fixture-chat" }
  : command === "send" ? { outcome: "completed", text } : command === "inspect" ? snapshot : {};
console.log(JSON.stringify(result));
`);
    await chmod(join(directory, "bun"), 0o755);
    const inventory = { devices: { "com.apple.CoreSimulator.SimRuntime.iOS-27-0":
      state === "missing" ? [] : [{ name: "ox-5", state, isAvailable: true }] } };
    const child = Bun.spawn(["bash", join(ROOT, "scripts/ios-ci.sh"), ...args], {
      cwd: directory, env: { ...Bun.env, PATH: `${directory}:${Bun.env.PATH}`, TMPDIR: directory,
        OX_QA_DEVICE: "", OX_BUNDLE_ID: "ai.openox.local", IOS_TRACE: trace,
        IOS_INVENTORY: JSON.stringify(inventory), IOS_LAUNCH_FAIL: String(launchFails) },
      stdout: "pipe", stderr: "pipe",
    });
    const [code, stdout, stderr] = await Promise.all([
      child.exited, new Response(child.stdout).text(), new Response(child.stderr).text(),
    ]);
    const lines = await readFile(trace, "utf8").catch(() => "");
    const calls: string[][] = lines.trim() ? lines.trim().split("\n").map(line => JSON.parse(line)) : [];
    expect(await Bun.file(join(directory, "ox-qa-tests/ox-5.lock")).exists()).toBe(false);
    return { code, stdout, stderr, calls };
  } finally { await rm(directory, { recursive: true, force: true }); }
}

test("iOS CI requires an explicit valid target and does not provision missing devices", async () => {
  for (const args of [[], ["--device", "ox-6"], ["--device", "ox-5", "--host", "ws://127.0.0.1:9876"]]) {
    const result = await ios(args);
    expect(result.code).toBe(1);
    expect(result.calls).toEqual([]);
  }
  const result = await ios(["--device", "ox-5"], "missing");
  expect(result.code).toBe(1);
  expect(result.stderr).toContain("unavailable");
  expect(result.calls).toEqual([["devices"]]);
});

test("iOS CI build failures preserve data/settings and restore prior boot state", async () => {
  for (const state of ["Booted", "Shutdown"]) {
    const result = await ios(["--device", "ox-5"], state, true);
    expect(result.code).toBe(1);
    expect(result.stderr).toContain("fixture build failed");
    expect(result.calls.filter(call => call.some(word => ["uninstall", "clone", "erase", "defaults"].includes(word)))).toEqual([]);
    expect(result.calls.filter(call => call[1] === "shutdown"))
      .toEqual(state === "Shutdown" ? [["devices", "shutdown", "ox-5"]] : []);
  }
});

test("iOS CI orchestrates a Mock smoke against stubbed sim/Ox commands", async () => {
  const result = await ios(["--device", "ox-5"]);
  expect(result.code).toBe(0);
  expect(result.stdout).toContain("PASS iOS build, launch, Mock reply");
  expect(result.calls).toContainEqual(["--device", "ox-5", "wait", "--id", "chat.message.agent", "--timeout", "10000"]);
  expect(result.calls.some(call => call[0] === "ox" && call.includes("mock") && call.includes("--temporary"))).toBe(true);
  expect(result.calls.some(call => call.includes("screenshot"))).toBe(true);
  expect(result.calls.some(call => call.includes("uninstall") || call.includes("defaults"))).toBe(false);
  expect(result.calls.some(call => call.includes("shutdown"))).toBe(false);
});
