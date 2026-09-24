import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const source = readFileSync(join(import.meta.dir, "../apps/ios/Ox/Host/Services/Web/ServiceActionRuntime.js"), "utf8");
const helperSource = readFileSync(join(import.meta.dir, "../apps/ios/Ox/Resources/SystemSkills.bundle/manage-services/references/helpers.js"), "utf8");
const apiServiceSource = readFileSync(join(import.meta.dir, "../apps/ios/Ox/Host/Services/API/APIService.swift"), "utf8");
const apiInstaller = apiServiceSource.match(/private static let installer = #"""\n([\s\S]*?)\n    """#/)?.[1];
if (!apiInstaller) throw new Error("API installer source is missing");

function runtime(version: number) {
  const window = {
    location: { href: "https://example.com/" },
    fetch: async () => ({ ok: true, status: 200 }),
  } as Record<string, any>;
  const document = { cookie: "session=present" };
  new Function("window", "document", "Request", source)(window, document, Request);
  return { window, service: window.__openOxCreateServiceRuntime("example.com", version) };
}

function apiRuntime(version: number) {
  const request = async () => ({ value: "ok" });
  return new Function("__apiRequest", "__serviceVersion", `${apiInstaller}\nreturn { window, __invokeAPI };`)(request, version);
}

test("version 1 retains the legacy installer and capture", async () => {
  const { window, service } = runtime(1);
  service.install(({ action, retryFetch, log, lib }: Record<string, any>) => {
    expect(typeof retryFetch).toBe("function");
    expect(typeof log).toBe("function");
    expect(lib.cleanText(" a  b ")).toBe("a b");
    action("value", { invoke: () => ({ value: lib.cookie("session") }) });
  });
  expect(typeof window.oxFetchCapture).toBe("function");
  expect(await service.callServiceAction("value")).toEqual({ value: "present" });
});

test("version 2 provides only action and does not install capture", async () => {
  const { window, service } = runtime(2);
  service.install(({ action }: Record<string, any>) => {
    action("value", { invoke: () => ({ value: "ok" }) });
  });
  expect(window.oxFetchCapture).toBeUndefined();
  expect(await service.callServiceAction("value")).toEqual({ value: "ok" });
});

test("version 2 rejects access to legacy helpers during installation", () => {
  const { service } = runtime(2);
  expect(() => service.install(({ retryFetch }: Record<string, any>) => retryFetch)).toThrow(
    "service version 2 does not provide retryFetch",
  );
});

test.each([
  { version: 2, arguments: [2, () => {}], error: "window.ox.install takes only the installer; the repository declares the version" },
  { version: 2, arguments: [() => {}, 2], error: "window.ox.install takes only the installer; the repository declares the version" },
  { version: 3, arguments: [() => {}], error: "unsupported service version: 3" },
])("invalid installs fail: %j", ({ version, arguments: args, error }) => {
  expect(() => runtime(version).service.install(...args)).toThrow(error);
  expect(() => apiRuntime(version).window.ox.install(...args)).toThrow(version === 3 ? "Invalid API installer" : error);
});

test("API version 1 remains compatible", async () => {
  const { window, __invokeAPI } = apiRuntime(1);
  window.ox.install(({ action, request, log, lib }: Record<string, any>) => {
    expect(typeof log).toBe("function");
    expect(lib.cleanText(" a  b ")).toBe("a b");
    action("value", { invoke: () => request({ path: "/value" }) });
  });
  expect(await __invokeAPI("value", {}, ["value"])).toEqual({ value: "ok" });
});

test("API version 2 provides action and request but no helpers", async () => {
  const { window, __invokeAPI } = apiRuntime(2);
  window.ox.install(({ action, request }: Record<string, any>) => {
    action("value", { invoke: () => request({ path: "/value" }) });
  });
  expect(await __invokeAPI("value", {}, ["value"])).toEqual({ value: "ok" });
});

test("API version 2 rejects legacy helper access", () => {
  const { window } = apiRuntime(2);
  expect(() => window.ox.install(({ lib }: Record<string, any>) => lib)).toThrow(
    "service version 2 does not provide lib",
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
