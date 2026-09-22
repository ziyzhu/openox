import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const source = readFileSync(join(import.meta.dir, "../apps/ios/Ox/Host/Services/Web/ServiceActionRuntime.js"), "utf8");
const helperSource = readFileSync(join(import.meta.dir, "../apps/ios/Ox/Resources/SystemSkills.bundle/manage-services/references/helpers.js"), "utf8");
const apiServiceSource = readFileSync(join(import.meta.dir, "../apps/ios/Ox/Host/Services/API/APIService.swift"), "utf8");
const apiInstaller = apiServiceSource.match(/private static let installer = #"""\n([\s\S]*?)\n    """#/)?.[1];
if (!apiInstaller) throw new Error("API installer source is missing");

function runtime() {
  const window = {
    location: { href: "https://example.com/" },
    fetch: async () => ({ ok: true, status: 200 }),
  } as Record<string, any>;
  const document = { cookie: "session=present" };
  new Function("window", "document", "Request", source)(window, document, Request);
  return { window, service: window.__openOxCreateServiceRuntime("example.com") };
}

function apiRuntime() {
  const request = async () => ({ value: "ok" });
  return new Function("__apiRequest", `${apiInstaller}\nreturn { window, __invokeAPI };`)(request);
}

test("ABI 1 retains the legacy installer and capture", async () => {
  const { window, service } = runtime();
  service.install(1, ({ action, retryFetch, log, lib }: Record<string, any>) => {
    expect(typeof retryFetch).toBe("function");
    expect(typeof log).toBe("function");
    expect(lib.cleanText(" a  b ")).toBe("a b");
    action("value", { invoke: () => ({ value: lib.cookie("session") }) });
  });
  expect(typeof window.oxFetchCapture).toBe("function");
  expect(await service.callServiceAction("value")).toEqual({ value: "present" });
});

test("ABI 2 provides only action and does not install capture", async () => {
  const { window, service } = runtime();
  service.install(2, ({ action }: Record<string, any>) => {
    action("value", { invoke: () => ({ value: "ok" }) });
  });
  expect(window.oxFetchCapture).toBeUndefined();
  expect(await service.callServiceAction("value")).toEqual({ value: "ok" });
});

test("ABI 2 rejects access to legacy helpers during installation", () => {
  const { service } = runtime();
  expect(() => service.install(2, ({ retryFetch }: Record<string, any>) => retryFetch)).toThrow(
    "service action ABI 2 does not provide retryFetch",
  );
});

test("API ABI 1 remains compatible", async () => {
  const { window, __invokeAPI } = apiRuntime();
  window.ox.install(1, ({ action, request, log, lib }: Record<string, any>) => {
    expect(typeof log).toBe("function");
    expect(lib.cleanText(" a  b ")).toBe("a b");
    action("value", { invoke: () => request({ path: "/value" }) });
  });
  expect(await __invokeAPI("value", {}, ["value"])).toEqual({ value: "ok" });
});

test("API ABI 2 provides action and request but no helpers", async () => {
  const { window, __invokeAPI } = apiRuntime();
  window.ox.install(2, ({ action, request }: Record<string, any>) => {
    action("value", { invoke: () => request({ path: "/value" }) });
  });
  expect(await __invokeAPI("value", {}, ["value"])).toEqual({ value: "ok" });
});

test("API ABI 2 rejects legacy helper access", () => {
  const { window } = apiRuntime();
  expect(() => window.ox.install(2, ({ lib }: Record<string, any>) => lib)).toThrow(
    "service action ABI 2 does not provide lib",
  );
});

test("copyable fetch capture observes a matching response and replays the latest result", async () => {
  const window = {
    location: { href: "https://example.com/page" },
    fetch: async (_input: string) => ({ clone: () => ({ json: async () => ({ value: "captured" }) }) }),
  };
  const createFetchCapture = new Function("window", "document", "Request", `${helperSource}\nreturn createFetchCapture;`)(
    window,
    { cookie: "" },
    Request,
  );
  const waitForCapture = createFetchCapture(window);
  const pending = waitForCapture(/\/api\/value/, { timeoutMs: 100 });
  await window.fetch("https://example.com/api/value");
  expect(await pending).toEqual({ value: "captured" });
  expect(await waitForCapture(/\/api\/value/, { replayLatest: true })).toEqual({ value: "captured" });
});
