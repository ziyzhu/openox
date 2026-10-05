import { beforeAll, expect, it } from "bun:test";
import { createContext, runInContext } from "node:vm";

beforeAll(async () => {
  const build = Bun.spawn(["bun", "packages/agent/build.ts"], { cwd: new URL("../../../", import.meta.url).pathname, stdout: "pipe", stderr: "pipe" });
  const [code, stderr] = await Promise.all([build.exited, new Response(build.stderr).text()]);
  expect(code, stderr).toBe(0);
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
