import { beforeAll, expect, it } from "bun:test";
import { createContext, runInContext } from "node:vm";
import { responseDirective } from "../src/core/prompts";
import { providerIdentity } from "../src/core/provider-prompts";
import { guidanceTexts } from "../src/core/guidance-texts";
import { nativeGuidanceSource } from "../native-guidance";
import { bundledSkills } from "../src/core/bundled-skills";

beforeAll(async () => {
  const build = Bun.spawn(["bun", "packages/agent/build.ts"], { cwd: new URL("../../../", import.meta.url).pathname, stdout: "pipe", stderr: "pipe" });
  const [code, stderr] = await Promise.all([build.exited, new Response(build.stderr).text()]);
  expect(code, stderr).toBe(0);
});

it("ships a standalone prompt renderer without a Profile, native bridge, or separate voice resource", async () => {
  const directory = new URL("../../../apps/shared/Resources/PiDurable.bundle/", import.meta.url);
  const realm = createContext({ console: undefined });
  runInContext(await Bun.file(new URL("prompts.js", directory)).text(), realm);
  expect(runInContext("typeof OxDurable + ':' + typeof __oxDurableRequest + ':' + typeof process + ':' + typeof fetch", realm))
    .toBe("undefined:undefined:undefined:undefined");
  for (const language of [null, { identifier: "zh-Hans", name: "Chinese (Simplified)" }, { identifier: "fr_FR", name: "French (France)" }]) {
    realm.language = language;
    expect(runInContext("OxPrompts.responseDirective(language)", realm)).toBe(responseDirective(language));
  }
  expect(() => runInContext("OxPrompts.responseDirective({})", realm)).toThrow("Response language requires");
  for (const [key, text] of Object.entries(guidanceTexts)) {
    realm.key = key;
    expect(runInContext("OxPrompts.guidanceText(key)", realm)).toBe(text);
  }
  expect(runInContext("OxPrompts.providerIdentity('claude-subscription')", realm)).toBe(providerIdentity("claude-subscription"));
  expect(() => runInContext("OxPrompts.guidanceText('__proto__')", realm)).toThrow("Unknown model guidance");
  realm.event = { type: "serviceLogin", domain: "example.com", authorized: true };
  expect(runInContext("OxPrompts.runtimeEvent(event)", realm)).toBe("[system] The user just authorized example.com. Continue the task that needed it.");
  realm.receipt = { invocations: Array.from({ length: 21 }, (_, index) => ({ id: String(index), name: "药💊".repeat(200), state: "running" })) };
  const receipt = runInContext("OxPrompts.failureReceipt(receipt)", realm) as string;
  expect(receipt).toContain("1 middle calls omitted");
  expect(receipt).toContain("药💊".repeat(80));
  expect(receipt).not.toContain("药💊".repeat(81));
  expect(receipt).toContain("incomplete/unknown outcome: 21");
  expect(() => runInContext("OxPrompts.failureReceipt({invocations:[{id:'x',name:'x',state:'__proto__'}]})", realm)).toThrow("Invalid receipt invocation");
  for (const skill of bundledSkills) for (const [path, text] of Object.entries(skill.files)) {
    const source = await Bun.file(new URL(`../skills/${skill.name}/${path}`, import.meta.url)).text();
    expect(text).toBe(source);
  }
  const nativeSource = await Bun.file(new URL("../../../apps/shared/Runtime/Agent/ModelGuidance.generated.swift", import.meta.url)).text();
  expect(nativeSource).toBe(nativeGuidanceSource());
  expect(await Bun.file(new URL("default-soul.md", directory)).exists()).toBe(false);
  const manifest = await Bun.file(new URL("manifest.json", directory)).json();
  expect(manifest.resources).toEqual({});
});

it("shares the core across hosts and rejects ambiguous ownership in the shipped renderer", async () => {
  const realm = createContext({ console: undefined });
  runInContext(await Bun.file(new URL("../../../apps/shared/Resources/PiDurable.bundle/prompts.js", import.meta.url)).text(), realm);
  const scope = { deviceID: "desktop-host", profileID: "profile-a" };
  realm.input = { memory: "frozen", deviceContext: { active: scope,
    devices: [{ ...scope, functions: ["ox.fs.read", "ox.fs.edit", "ox.fs.write"], serviceKinds: [], presentation: "text", externalFiles: false }] } };
  const prompt = runInContext("OxPrompts.composeOxPrompt(input).rendered", realm) as string;
  expect(prompt).toContain("frozen");
  expect(prompt).not.toContain("iOS");
  expect(prompt).not.toContain("ox.app");
  expect(prompt).not.toContain("mounts/<folder-id>");
  expect(prompt).not.toContain("ox.service.showPage");
  expect(() => runInContext("OxPrompts.composeOxPrompt({...input,deviceContext:{...input.deviceContext,active:{deviceID:'wrong',profileID:'profile-a'}}})", realm)).toThrow("unavailable");
  expect(() => runInContext("OxPrompts.composeOxPrompt({...input,deviceContext:{...input.deviceContext,devices:[...input.deviceContext.devices,...input.deviceContext.devices]}})", realm)).toThrow("Duplicate");
  expect(runInContext("OxPrompts.composeOxPrompt({...input,deviceContext:{...input.deviceContext,devices:[{...input.deviceContext.devices[0],functions:['ox'],serviceKinds:['web','api','ios','mcp'],presentation:'conversation-bubbles',externalFiles:true}]}}).rendered", realm)).toBe(prompt);
  realm.guide = { catalog: "ox.fs.read", timeoutSeconds: 10, maxOutputTokens: 100, canCancelLoops: true };
  const guide = runInContext("OxPrompts.executeGuidance(guide)", realm) as string;
  expect(guide).toContain("10 seconds");
  expect(guide).toContain("about 100 tokens");
  expect(guide).toContain("ox.service.inspect");
  expect(guide).toContain("ox.web.browser.showPage");
  expect(guide).toContain("declare namespace ox.web");
  expect(guide).toContain("function fetch(args:");
  expect(guide).not.toContain("does not forcibly stop");
  expect(guide).toContain("supports interrupting JavaScript loops");
  expect(guide).toContain("synchronous .help()");
});

for (const name of ["harness", "harness-storage"]) {
  it(`loads audited ${name} in a bare realm without Node or browser globals`, async () => {
    const source = await Bun.file(new URL(`../../../apps/shared/Resources/PiDurable.bundle/${name}.js`, import.meta.url)).text();
    let next = 0;
    const timers = new Map<number, ReturnType<typeof setTimeout>>();
    const realm = createContext({
      console: undefined,
      SharedArrayBuffer: undefined,
      __oxDurableLog() {},
      __oxDurableTimer(callback: () => void, ms: number) {
        const id = ++next;
        timers.set(id, setTimeout(() => { timers.delete(id); callback(); }, ms));
        return id;
      },
      __oxDurableClearTimer(id: number) { clearTimeout(timers.get(id)); timers.delete(id); },
    });
    try {
      runInContext(source, realm);
      expect(runInContext("typeof OxDurable.agentCommand", realm)).toBe(name === "harness" ? "function" : "undefined");
      expect(runInContext("typeof OxDurable.storageConformance", realm)).toBe(name === "harness-storage" ? "function" : "undefined");
      expect(runInContext("typeof OxDurable.storageBenchmark", realm)).toBe(name === "harness-storage" ? "function" : "undefined");
      expect(runInContext("typeof OxDurable.command", realm)).toBe("undefined");
      expect(runInContext("typeof process + ':' + typeof require + ':' + typeof fetch", realm)).toBe("undefined:undefined:undefined");
    } finally { for (const timer of timers.values()) clearTimeout(timer); }
  });
}
