import { beforeAll, expect, it } from "bun:test";
import { createContext, runInContext } from "node:vm";
import { defaultSoul, responseDirective } from "../src/core/prompts";
import { websiteInstructions, providerIdentity } from "../src/core/provider-prompts";
import { guidanceTexts } from "../src/core/guidance-texts";
import { nativeGuidanceSource } from "../native-guidance";

beforeAll(async () => {
  const build = Bun.spawn(["bun", "packages/agent/build.ts"], { cwd: new URL("../../../", import.meta.url).pathname, stdout: "pipe", stderr: "pipe" });
  const [code, stderr] = await Promise.all([build.exited, new Response(build.stderr).text()]);
  expect(code, stderr).toBe(0);
});

it("ships a standalone prompt renderer and byte-identical default SOUL without a Profile or native bridge", async () => {
  const directory = new URL("../../../apps/ios/Ox/Resources/PiDurable.bundle/", import.meta.url);
  const realm = createContext({ console: undefined });
  runInContext(await Bun.file(new URL("prompts.js", directory)).text(), realm);
  expect(runInContext("typeof OxDurable + ':' + typeof __oxDurableRequest + ':' + typeof process + ':' + typeof fetch", realm))
    .toBe("undefined:undefined:undefined:undefined");
  for (const language of [null, { identifier: "zh-Hans", name: "Chinese (Simplified)" }, { identifier: "fr_FR", name: "French (France)" }]) {
    realm.language = language;
    expect(runInContext("OxPrompts.responseDirective(language)", realm)).toBe(responseDirective(language));
  }
  for (const input of [
    { systemPrompt: null, actionsJSON: "" },
    { systemPrompt: "summarization instructions", actionsJSON: "" },
    { systemPrompt: "Ox instructions", actionsJSON: JSON.stringify([{ function: { description: "Read files / 文档", name: "execute", parameters: { type: "object" } }, type: "function" }]) },
  ]) {
    realm.input = input;
    const rendered = runInContext("OxPrompts.websiteInstructions(input)", realm) as string;
    expect(rendered).toBe(websiteInstructions(input));
    expect(rendered.includes("<ox_actions>")).toBe(input.actionsJSON !== "");
    expect(rendered).toContain("Continue the latest user request.");
  }
  expect(() => runInContext("OxPrompts.responseDirective({})", realm)).toThrow("Response language requires");
  expect(() => runInContext("OxPrompts.websiteInstructions({})", realm)).toThrow("Website prompt requires");
  for (const [key, text] of Object.entries(guidanceTexts)) {
    realm.key = key;
    expect(runInContext("OxPrompts.guidanceText(key)", realm)).toBe(text);
  }
  expect(runInContext("OxPrompts.providerIdentity('claude-subscription')", realm)).toBe(providerIdentity("claude-subscription"));
  expect(() => runInContext("OxPrompts.guidanceText('__proto__')", realm)).toThrow("Unknown model guidance");
  realm.event = { type: "serviceSignIn", domain: "example.com", authorized: true };
  expect(runInContext("OxPrompts.runtimeEvent(event)", realm)).toBe("[system] The user just authorized example.com. Continue the task that needed it.");
  realm.receipt = { invocations: Array.from({ length: 21 }, (_, index) => ({ id: String(index), name: "药💊".repeat(200), state: "running" })) };
  const receipt = runInContext("OxPrompts.failureReceipt(receipt)", realm) as string;
  expect(receipt).toContain("1 middle calls omitted");
  expect(receipt).toContain("药💊".repeat(80));
  expect(receipt).not.toContain("药💊".repeat(81));
  expect(receipt).toContain("incomplete/unknown outcome: 21");
  expect(() => runInContext("OxPrompts.failureReceipt({invocations:[{id:'x',name:'x',state:'__proto__'}]})", realm)).toThrow("Invalid receipt invocation");
  const nativeSource = await Bun.file(new URL("../../../apps/ios/Ox/Host/Agent/ModelGuidance.generated.swift", import.meta.url)).text();
  expect(nativeSource).toBe(nativeGuidanceSource());
  const seed = await Bun.file(new URL("default-soul.md", directory)).text();
  expect(seed).toBe(defaultSoul);
  const manifest = await Bun.file(new URL("manifest.json", directory)).json();
  expect(manifest.resources["default-soul.md"]).toEqual({ bytes: new TextEncoder().encode(seed).length,
    sha256: new Bun.CryptoHasher("sha256").update(seed).digest("hex") });
});

it("uses explicit prompt variants without inferring prose from capabilities and rejects ambiguous ownership in the shipped renderer", async () => {
  const realm = createContext({ console: undefined });
  runInContext(await Bun.file(new URL("../../../apps/ios/Ox/Resources/PiDurable.bundle/prompts.js", import.meta.url)).text(), realm);
  const scope = { hostID: "desktop-host", profileID: "profile-a" };
  realm.input = { soul: "## Voice\nBe direct.", memory: "frozen", hostContext: { active: scope,
    hosts: [{ ...scope, functions: ["ox.fs.read", "ox.fs.edit", "ox.fs.write", "ox.output.read"], serviceKinds: [], presentation: "text", externalFiles: false }] } };
  const prompt = runInContext("OxPrompts.composeOxPrompt(input).rendered", realm) as string;
  expect(prompt).toContain("text with Markdown support");
  expect(prompt).toContain("frozen");
  expect(prompt).not.toContain("iOS");
  expect(prompt).not.toContain("Browser");
  expect(prompt).not.toContain("ox.app");
  expect(prompt).not.toContain("files/<folder-id>");
  expect(prompt).not.toContain("ox.service");
  expect(() => runInContext("OxPrompts.composeOxPrompt({...input,hostContext:{...input.hostContext,active:{hostID:'wrong',profileID:'profile-a'}}})", realm)).toThrow("unavailable");
  expect(() => runInContext("OxPrompts.composeOxPrompt({...input,hostContext:{...input.hostContext,hosts:[...input.hostContext.hosts,...input.hostContext.hosts]}})", realm)).toThrow("Duplicate");
  expect(runInContext("OxPrompts.composeOxPrompt({...input,hostContext:{...input.hostContext,hosts:[{...input.hostContext.hosts[0],functions:['ox'],serviceKinds:['web','api','ios','mcp'],presentation:'chat-bubbles',externalFiles:true}]}}).rendered", realm)).toBe(prompt);
  const full = runInContext("OxPrompts.composeOxPrompt(input,false,OxPrompts.oxScaffold).rendered", realm) as string;
  expect(full).toContain("ox.service.find");
  expect(full).toContain("ox.web.browser.waitForUserInteraction");
  realm.guide = { catalog: "ox.fs.read", variant: "portable", timeoutSeconds: 10, maxLines: 100, maxBytes: 2048, canCancelLoops: true };
  const guide = runInContext("OxPrompts.executeGuidance(guide)", realm) as string;
  expect(guide).toContain("10 seconds");
  expect(guide).toContain("100 lines or 2 KiB");
  expect(guide).not.toContain("ox.service.inspect");
  expect(guide).not.toContain("ox.web.fetch");
  expect(guide).not.toContain("does not forcibly stop");
  expect(guide).toContain("supports interrupting JavaScript loops");
  expect(runInContext("OxPrompts.executeGuidance({...guide,variant:'ox'})", realm)).toContain("ox.service.inspect");
  expect(runInContext("OxPrompts.executeGuidance({...guide,variant:'website'})", realm)).not.toContain("ox.service.inspect");
  expect(() => runInContext("OxPrompts.executeGuidance({...guide,variant:'__proto__'})", realm)).toThrow("Unknown execution guidance variant");
});

for (const name of ["harness", "harness-storage"]) {
  it(`loads audited ${name} in a bare realm without Node or browser globals`, async () => {
    const source = await Bun.file(new URL(`../../../apps/ios/Ox/Resources/PiDurable.bundle/${name}.js`, import.meta.url)).text();
    let next = 0;
    const timers = new Map<number, ReturnType<typeof setTimeout>>();
    const realm = createContext({
      console: undefined,
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
