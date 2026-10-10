import { expect, test } from "bun:test";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ROOT } from "../../../../lib.ts";

async function ios(args: string[], state = "Booted", launchFails = false, temporary = true, bundle = "ai.openox.local") {
  const directory = await mkdtemp(join(tmpdir(), "openox-ios-ci-e2e-"));
  const trace = join(directory, "calls.jsonl");
  try {
    for (const tool of ["xcrun", "xcodebuild", "idb", "plutil"]) {
      await writeFile(join(directory, tool), `#!${process.execPath}
import { appendFileSync } from "node:fs";
import { basename } from "node:path";
const args = Bun.argv.slice(2), tool = basename(Bun.argv[1]);
const call = [tool, ...args];
if (args.includes("launch")) call.push("SIMCTL_CHILD_OX_HOST_LOOPBACK=" + Bun.env.SIMCTL_CHILD_OX_HOST_LOOPBACK);
appendFileSync(Bun.env.IOS_TRACE, JSON.stringify(call) + "\\n");
if (tool === "plutil") console.log(Bun.env.IOS_APP_BUNDLE);
else if (tool === "xcrun" && args[1] === "list") console.log(Bun.env.IOS_INVENTORY);
else if (tool === "xcodebuild" && Bun.env.IOS_LAUNCH_FAIL === "true") { console.error("fixture build failed"); process.exit(1); }
else if (tool === "idb" && args[1] === "describe-all") console.log(JSON.stringify([{ AXUniqueId: "chat.message.agent", frame: { x: 0, y: 0, width: 44, height: 44 } }]));
else console.log("{}");
`);
      await chmod(join(directory, tool), 0o755);
    }
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
const result = command === "list" ? [] : command === "new" ? { chatId: "fixture-chat", temporary: Bun.env.IOS_TEMPORARY === "true", model: "mock:mock" }
  : command === "send" ? { outcome: "completed", text } : command === "inspect" ? snapshot : {};
console.log(JSON.stringify(result));
`);
    await chmod(join(directory, "bun"), 0o755);
    const inventory = { devices: { "com.apple.CoreSimulator.SimRuntime.iOS-27-0":
      state === "missing" ? [] : [{ name: "ox-5", udid: "fixture-ox-5", state, isAvailable: true }] } };
    const child = Bun.spawn([join(directory, "bun"), "run", "--cwd", ROOT, "ci:ios", ...args], {
      cwd: directory, env: { ...Bun.env, PATH: `${directory}:${Bun.env.PATH}`, TMPDIR: directory,
        OX_QA_DEVICE: "", OX_BUNDLE_ID: "ai.openox.local", IOS_TRACE: trace,
        IOS_INVENTORY: JSON.stringify(inventory), IOS_LAUNCH_FAIL: String(launchFails), IOS_TEMPORARY: String(temporary), IOS_APP_BUNDLE: bundle },
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
  for (const args of [[], ["--device", "ox-6"], ["--device", "ox-5", "--host", "ws://127.0.0.1:9876"], ["--device", "ox-5", "--loopback", "--host", "ws://100.64.0.1:9105"]]) {
    const result = await ios(args);
    expect(result.code).toBe(1);
    expect(result.calls).toEqual([]);
  }
  const result = await ios(["--device", "ox-5"], "missing");
  expect(result.code).toBe(1);
  expect(result.stderr).toContain("unavailable");
  expect(result.calls).toEqual([["xcrun", "simctl", "list", "devices", "available", "--json"]]);
  const mismatch = await ios(["--device", "ox-5", "--app", "/tmp/fixture/Ox.app"], "Booted", false, true, "other.app");
  expect(mismatch.code).toBe(1);
  expect(mismatch.stderr).toContain("does not match");
  expect(mismatch.calls.some(call => call.includes("install") || call.includes("launch") || call[0] === "xcodebuild")).toBe(false);
});

test("iOS CI build failures preserve data/settings and restore prior boot state", async () => {
  for (const state of ["Booted", "Shutdown"]) {
    const result = await ios(["--device", "ox-5"], state, true);
    expect(result.code).toBe(1);
    expect(result.stderr).toContain("fixture build failed");
    expect(result.calls.filter(call => call.some(word => ["uninstall", "clone", "erase", "defaults"].includes(word)))).toEqual([]);
    expect(result.calls.filter(call => call.includes("shutdown")))
      .toEqual(state === "Shutdown" ? [["xcrun", "simctl", "shutdown", "fixture-ox-5"]] : []);
    expect(result.calls.some(call => call.includes("install"))).toBe(false);
  }
});

test("iOS CI orchestrates a Mock smoke against stubbed native/Ox commands", async () => {
  for (const loopback of [false, true]) {
    const result = await ios(["--device", "ox-5", ...(loopback ? ["--loopback", "--app", "/tmp/fixture/Ox.app"] : [])]);
    expect(result.code).toBe(0);
    expect(result.calls.some(call => call.includes(`SIMCTL_CHILD_OX_HOST_LOOPBACK=${loopback ? "1" : "0"}`))).toBe(true);
    expect(result.stdout).toContain(`PASS iOS ${loopback ? "prebuilt app" : "build"}, launch, Mock reply`);
    expect(result.calls).toContainEqual(["idb", "ui", "describe-all", "--udid", "fixture-ox-5"]);
    expect(result.calls.some(call => call[0] === "xcodebuild" && call.includes("platform=iOS Simulator,id=fixture-ox-5"))).toBe(!loopback);
    expect(result.calls.some(call => call[0] === "ox" && call.includes("mock") && call.includes("--temporary"))).toBe(true);
    expect(result.calls.some(call => call.slice(0, 5).join(" ") === "xcrun simctl io fixture-ox-5 screenshot")).toBe(true);
    expect(result.calls.some(call => call[0] === "idb" && call.includes("screenshot"))).toBe(false);
    expect(result.calls.some(call => call.includes("uninstall") || call.includes("defaults"))).toBe(false);
    expect(result.calls.some(call => call.includes("shutdown"))).toBe(false);
  }
});

test("iOS CI refuses a non-temporary chat before submitting a model prompt", async () => {
  const result = await ios(["--device", "ox-5", "--loopback"], "Booted", false, false);
  expect(result.code).toBe(1);
  expect(result.stderr).toContain("requested temporary Mock chat");
  expect(result.calls.some(call => call.includes("send"))).toBe(false);
});
