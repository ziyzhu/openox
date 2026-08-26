import { describe, expect, test } from "bun:test";
import { join } from "node:path";
import { ROOT } from "./lib.ts";

const source = await Bun.file(join(ROOT, "apps/ios/Ox/Host/Canvas/CanvasSDK.js")).text();
const catalog = {
  schemas: {
    "ox.service.invoke": {},
    "ox.service.find": {},
    "ox.service.git.status": {},
  },
  help: { "ox.service.invoke": "invoke input and output contract" },
};

type Request = { function: string; arguments: Record<string, unknown> };
type SDK = {
  service: {
    invoke: ((args: unknown) => Promise<unknown>) & { help: () => string };
    find: (args: unknown) => Promise<unknown>;
    git: { status: (args: unknown) => Promise<unknown> };
  };
};

function sdk(send: (request: Request) => Promise<unknown>): SDK {
  const target: { __oxCreateCanvasSDK?: (catalog: unknown, send: unknown) => SDK } = {};
  new Function("globalThis", source)(target);
  return target.__oxCreateCanvasSDK!(catalog, send);
}

describe("canvas service SDK", () => {
  test("sends catalogued calls and returns the Host result", async () => {
    const calls: Request[] = [];
    const ox = sdk(async request => {
      calls.push(request);
      return { ok: true, value: { items: [1, 2] } };
    });
    const args = { name: "web:example.com:list", input: { limit: 2 }, purpose: "Refresh items" };
    expect(await ox.service.invoke(args)).toEqual({ items: [1, 2] });
    await ox.service.git.status({ purpose: "Inspect services" });
    expect(calls).toEqual([
      { function: "ox.service.invoke", arguments: args },
      { function: "ox.service.git.status", arguments: { purpose: "Inspect services" } },
    ]);
  });

  test("help is synchronous and does not call the Host", () => {
    let calls = 0;
    const ox = sdk(async () => { calls += 1; return { ok: true }; });
    expect(ox.service.invoke.help()).toContain(catalog.help["ox.service.invoke"]);
    expect(Object.keys(ox.service.invoke)).not.toContain("help");
    expect(calls).toBe(0);
  });

  test("freezes namespaces and exposes only generated functions", () => {
    const ox = sdk(async () => ({ ok: true }));
    expect(Object.keys(ox)).toEqual(["service"]);
    expect(Object.keys(ox.service).sort()).toEqual(["find", "git", "invoke"]);
    expect(Object.isFrozen(ox.service.git)).toBe(true);
    expect(Reflect.set(ox.service, "invoke", () => undefined)).toBe(false);
  });

  test("rejects invalid, cyclic, and oversized arguments before dispatch", async () => {
    let calls = 0;
    const ox = sdk(async () => { calls += 1; return { ok: true }; });
    const cyclic: Record<string, unknown> = {};
    cyclic.self = cyclic;
    for (const args of [null, [], "input", { n: NaN }, { n: Infinity }, { f() {} }, { n: 1n }, cyclic, { text: "界".repeat(400_000) }]) {
      await expect(ox.service.invoke(args)).rejects.toThrow();
    }
    expect(calls).toBe(0);
  });

  test("surfaces failures without retrying", async () => {
    let calls = 0;
    const ox = sdk(async () => { calls += 1; return { ok: false, error: "The user declined" }; });
    await expect(ox.service.invoke({ purpose: "Run action" })).rejects.toThrow("The user declined");
    expect(calls).toBe(1);
  });

  test("rejects invalid replies and preserves null results", async () => {
    await expect(sdk(async () => null).service.find({ query: "test" })).rejects.toThrow("Invalid Host response");
    expect(await sdk(async () => ({ ok: true, value: null })).service.invoke({})).toBeNull();
  });
});
