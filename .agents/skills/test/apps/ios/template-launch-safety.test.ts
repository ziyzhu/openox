import { expect, test } from "bun:test";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ROOT } from "../../../../lib.ts";

test("template bootstrap uses the installed artifact without reinstalling it or resetting the target", async () => {
  const directory = await mkdtemp(join(tmpdir(), "openox-template-launch-e2e-"));
  const app = join(directory, "Ox.app");
  const data = join(directory, "data");
  const trace = join(directory, "calls.jsonl");
  try {
    await mkdir(app);
    await mkdir(data);
    await writeFile(join(app, "Ox"), "OX_DEVICE_TEMPLATE");
    await writeFile(join(app, "Info.plist"), "fixture");
    const template = join(directory, "template.json");
    await writeFile(template, JSON.stringify({ version: 1 }));
    for (const tool of ["xcrun", "idb", "plutil"]) {
      await writeFile(join(directory, tool), `#!${process.execPath}
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
const tool = basename(Bun.argv[1]), args = Bun.argv.slice(2);
appendFileSync(Bun.env.TEMPLATE_TRACE, JSON.stringify([tool, ...args]) + "\\n");
if (tool === "plutil") {
  if (!existsSync(args.at(-1))) process.exit(1);
  const fields = { CFBundleIdentifier: "qa.template", DTPlatformName: "iphonesimulator", CFBundleExecutable: "Ox", OXAppGroupIdentifier: "group.qa.template", CFBundleShortVersionString: "1", CFBundleVersion: "1" };
  console.log(fields[args[1]]);
} else if (tool === "idb") console.log("[]");
else if (args[1] === "list") console.log(JSON.stringify({ devices: { "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [{ name: "ox-5", udid: "fixture-ox-5", state: "Booted", isAvailable: true }] } }));
else if (args[1] === "get_app_container") console.log(args.at(-1) === "app" ? Bun.env.TEMPLATE_APP : Bun.env.TEMPLATE_DATA);
else if (args[1] === "launch") {
  const control = join(Bun.env.TEMPLATE_DATA, "Library/Caches/DeviceTemplates", Bun.env.SIMCTL_CHILD_OX_DEVICE_TEMPLATE);
  const input = JSON.parse(readFileSync(join(control, "input.json"), "utf8"));
  if (input.version !== 1) process.exit(1);
  writeFileSync(join(control, "result.json"), JSON.stringify({ status: "applied", profiles: {}, chats: {} }));
} else if (args[1] === "io") writeFileSync(args.at(-1), "fixture screenshot");
`);
      await chmod(join(directory, tool), 0o755);
    }
    const child = Bun.spawn([process.execPath, "run", "sim:bootstrap", "--device", "ox-5", "--bundle", "qa.template", "--template", template, "--output", directory], {
      cwd: ROOT,
      env: { ...Bun.env, PATH: `${directory}:${Bun.env.PATH}`, TMPDIR: directory, TEMPLATE_TRACE: trace, TEMPLATE_APP: app, TEMPLATE_DATA: data },
      stdout: "pipe", stderr: "pipe",
    });
    const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
    expect({ code, stderr }).toEqual({ code: 0, stderr: expect.any(String) });
    expect(stdout).toContain("APPLIED ox-5");
    const calls: string[][] = (await readFile(trace, "utf8")).trim().split("\n").map(line => JSON.parse(line));
    expect(calls.some(call => call.includes("launch") && call.includes("fixture-ox-5"))).toBe(true);
    expect(calls.some(call => call.some(arg => ["install", "erase", "uninstall", "shutdown", "clone"].includes(arg)))).toBe(false);
    expect(await Bun.file(join(directory, "ox-qa-tests/ox-5.lock")).exists()).toBe(false);
  } finally { await rm(directory, { recursive: true, force: true }); }
});
