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
  new Function("window", source)(window);
  return { window, service: window.__openOxCreateServiceRuntime("example.com") };
}

function apiRuntime() {
  const request = async () => ({ value: "ok" });
  return new Function("__apiRequest", `${apiInstaller}\nreturn { window, __invokeAPI };`)(request);
}

test("web installers execute actions without changing page fetch", async () => {
  const { window, service } = runtime();
  const fetch = window.fetch;
  service.install(({ action }: Record<string, any>) => {
    action("value", { invoke: () => ({ value: "ok" }) });
  });
  expect(window.fetch).toBe(fetch);
  expect(await service.callServiceAction("value")).toEqual({ value: "ok" });
});

test("API installers receive action and request", async () => {
  const { window, __invokeAPI } = apiRuntime();
  window.ox.install(({ action, request }: Record<string, any>) => {
    action("value", { invoke: () => request({ path: "/value" }) });
  });
  expect(await __invokeAPI("value", {}, ["value"])).toEqual({ value: "ok" });
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
