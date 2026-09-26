import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { serviceSource } from "../fixtures/model-service-source";
import { replayCases } from "../../repositories/builtin/web/chat.deepseek.com/replay";

function signInProbe(response: unknown, error?: unknown) {
  const actions = new Map<string, { invoke: () => Promise<unknown> }>();
  const calls: Array<{ url: string; options: any }> = [];
  let stored: string | null = JSON.stringify({ value: "synthetic-token", __version: 0 });
  const window = {
    rspackChunk_deepseek_chat: { push() { throw new Error("Native client can retain stale authentication and clear login"); } },
    ox: { install: (install: any) => install({ action: (name: string, value: any) => actions.set(name, value) }) },
  };
  const localStorage = { getItem(key: string) { expect(key).toBe("userToken"); return stored; } };
  const fetch = async (url: string, options: any) => {
    calls.push({ url, options });
    if (error) throw error;
    return { status: (response as any).status, json: async () => (response as any).json };
  };
  new Function("window", "localStorage", "fetch", serviceSource("chat.deepseek.com"))(window, localStorage, fetch);
  return { invoke: () => actions.get("getSignInState")!.invoke(), calls, store: (value: string | null) => { stored = value; } };
}

const identityResponse = { status: 200, json: { code: 0, data: { biz_code: 0, biz_data: { id: "synthetic-account" } } } };

test("DeepSeek rechecks shared authentication after login in another page", async () => {
  const probe = signInProbe(identityResponse);
  probe.store(null);
  expect(await probe.invoke()).toEqual({ signedIn: false });
  expect(probe.calls).toHaveLength(0);
  for (const value of ["synthetic-login", "synthetic-refreshed"]) {
    probe.store(JSON.stringify({ value, __version: 0 }));
    expect(await probe.invoke()).toEqual({ signedIn: true });
    expect(probe.calls.at(-1)?.options.headers).toEqual({ Authorization: `Bearer ${value}` });
  }
  expect(probe.calls).toHaveLength(2);
  for (const call of probe.calls) {
    expect(call.url).toBe("/api/v0/users/current");
    expect(call.options.cache).toBe("no-store");
    expect(call.options.redirect).toBe("error");
    expect(call.options.signal).toBeInstanceOf(AbortSignal);
  }
});

test("DeepSeek skips unauthenticated requests while the handoff is signing in", async () => {
  const probe = signInProbe(identityResponse);
  for (const value of [null, "null", '{"value":null,"__version":0}']) {
    probe.store(value);
    expect(await probe.invoke()).toEqual({ signedIn: false });
  }
  expect(probe.calls).toHaveLength(0);
});

test("DeepSeek rejects malformed authentication storage without a request", async () => {
  const probe = signInProbe(identityResponse);
  for (const value of ["broken-json", "{}", '{"value":3}', '{"value":""}']) {
    probe.store(value);
    await expect(probe.invoke()).rejects.toThrow("Invalid DeepSeek sign-in storage");
  }
  expect(probe.calls).toHaveLength(0);
});

test("DeepSeek recognizes a missing-token response without clearing shared state", async () => {
  const probe = signInProbe({ status: 200, json: { code: 40002 } });
  expect(await probe.invoke()).toEqual({ signedIn: false });
  expect(await probe.invoke()).toEqual({ signedIn: false });
  expect(probe.calls).toHaveLength(2);
});

test("DeepSeek does not expose request error contents", async () => {
  await expect(signInProbe(null, new Error("private-context")).invoke()).rejects.toThrow("DeepSeek identity check failed");
});

test("DeepSeek requires a successful server identity", async () => {
  for (const response of [
    { status: 500, json: { code: 40002 } },
    { status: 200, json: { code: 0, data: { biz_code: 0, biz_data: { id: "" } } } },
    { status: 200, json: { code: 0, data: { biz_code: 1, biz_data: { id: "synthetic-account" } } } },
    { status: 200, json: {} },
  ]) {
    await expect(signInProbe(response).invoke()).rejects.toThrow("Unrecognized DeepSeek identity response");
  }
});

for (const fixture of replayCases) {
  test(`DeepSeek sanitized replay: ${fixture.name}`, async () => {
    const har = JSON.parse(readFileSync("repositories/builtin/web/chat.deepseek.com/actions.har", "utf8"));
    const entries = har.log.entries.filter((entry: any) => entry.pageref === `${fixture.action}:${fixture.name}`);
    const actions = new Map<string, { invoke: () => Promise<unknown> }>();
    const window = { ox: { install: (install: any) => install({ action: (name: string, value: any) => actions.set(name, value) }) } };
    const storage = new Map<string, string>();
    const localStorage = { getItem: (key: string) => storage.get(key) ?? null, setItem: (key: string, value: string) => storage.set(key, value) };
    let requests = 0;
    const fetch = async (url: string) => {
      const entry = entries.find((entry: any) => entry.request.url === new URL(url, "https://chat.deepseek.com").href);
      if (!entry) throw new Error(`Unmatched replay request: ${url}`);
      requests++;
      return new Response(entry.response.content.text, { status: entry.response.status });
    };
    const script = entries[0].response.content.text.match(/<script>([\s\S]*?)<\/script>/)[1];
    new Function("localStorage", script)(localStorage);
    new Function("window", "localStorage", "fetch", serviceSource("chat.deepseek.com"))(window, localStorage, fetch);
    expect(await actions.get(fixture.action)!.invoke()).toEqual(fixture.output);
    expect(requests).toBe(fixture.output.signedIn ? 1 : 0);
  });
}
