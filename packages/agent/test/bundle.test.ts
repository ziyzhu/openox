import { beforeAll, expect, it } from "bun:test";
import { createContext, runInContext } from "node:vm";
import { defaultSoul, responseDirective } from "../src/core/prompts";
import { websiteInstructions } from "../src/core/provider-prompts";

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
  const seed = await Bun.file(new URL("default-soul.md", directory)).text();
  expect(seed).toBe(defaultSoul);
  const manifest = await Bun.file(new URL("manifest.json", directory)).json();
  expect(manifest.resources["default-soul.md"]).toEqual({ bytes: new TextEncoder().encode(seed).length,
    sha256: new Bun.CryptoHasher("sha256").update(seed).digest("hex") });
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
