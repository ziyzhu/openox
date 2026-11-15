import { strict as assert } from "node:assert";
import { writeFile } from "node:fs/promises";
import { run } from "../../../../lib.ts";
import { elements } from "../../../setup/scripts/ios.ts";
import { invokeScript, type Case } from "./cases.ts";
import type { Harness } from "./harness.ts";

const scenarios = ["control", "slow", "stream", "server", "client", "loop", "timeout"];

export const handoffCases: Case[] = scenarios.map(scenario => ({
  name: `handoff-${scenario}`,
  site: "handoff",
  async run(h) {
    const domain = `ox-handoff-${scenario}.localhost`;
    const started = Date.now();
    await h.begin(`await (async () => { ${invokeScript(`web:${domain}:login`)} })();
const pages = (await ox.web.browser.pages({ purpose: "Find prepared handoff page" })).pages.filter(page => page.owned);
try { return { value: await ox.web.browser.showPage({ purpose: "Show stress handoff", pageId: pages[0].pageId }) }; }
catch (error) { return { error: error.message, code: error.code }; }`, true);
    const terminal = scenario === "loop" || scenario === "timeout";
    let result: any;
    if (terminal) result = h.lastResult(await h.idle());
    else await h.waitMatching(/^conversation\.service\.login\..+\.done$/, 20_000);
    const elapsedMs = Date.now() - started;
    const counters = Object.fromEntries(Object.entries(h.site("handoff").counters).filter(([key]) => key.startsWith(`${scenario}.`)).map(([key, value]) => [key.slice(scenario.length + 1), value]));
    try {
      assert.equal(counters.dispatches, 1, "login was not dispatched exactly once");
      assert.equal(counters.starts, 1, "login navigation was replayed");
      if (terminal) {
        assert.ok(result.error, `unsettled page reported success: ${JSON.stringify(result)}`);
        assert.match(result.error, /timed?\s*out|timeout/i, "unsettled page failed for a reason other than its deadline");
        assert.ok(elapsedMs >= 14_000 && elapsedMs < 25_000, `preflight did not respect its 15-second deadline: ${elapsedMs}ms`);
        assert.equal(counters.destinations ?? 0, 0, "fixture unexpectedly reached the destination");
        const recovery = await h.turn('return { recovered: true };');
        assert.equal(recovery.recovered, true, "failed handoff left the conversation locked");
        return `bounded failure in ${elapsedMs}ms, code=${result.code}, dispatches=1, hops=${counters.hops ?? 0}, conversation usable`;
      }
      assert.equal((await h.snapshot()).isBusy, true, "presentation must keep execution pending");
      assert.equal(counters.destinations, 1, "handoff appeared before the final destination was served");
      await h.tapMatching(/^serviceInspector\.open\./);
      await h.ios.wait({ id: "serviceHandoff.cancel" }, { timeout: 10_000, stable: 500 });
      try {
        await h.fillWeb("Email", "synthetic@fixture.test");
        await h.screenshot(`handoff-${scenario}`);
      } finally {
        await h.ios.tap({ id: "serviceHandoff.cancel" }, { stable: 300 });
        const cancelled = await h.idle();
        result = h.lastResult(cancelled);
        assert.deepEqual(result.value, { status: "cancelled" });
        assert.ok(!JSON.stringify(cancelled).includes("<user_interaction>"));
      }
      assert.equal(h.site("handoff").counters[`${scenario}.dispatches`], 1, "handoff cancellation replayed login");
      assert.deepEqual(await h.turn(invokeScript(`web:${domain}:listSessions`)), []);
      return `usable final-page field, cancel and session check passed; ${elapsedMs}ms, dispatches=1, hops=${counters.hops ?? 0}`;
    } finally {
      const logs = await h.ox(["host", "logs", "--grep", "Service.handoff", "--since", new Date(started).toISOString(), "--limit", "200"]);
      await writeFile(`${h.evidence}/${scenario}.json`, JSON.stringify({ scenario, result, elapsedMs, counters: { ...counters }, logs }, null, 2));
    }
  },
}));

handoffCases.push({
  name: "handoff-cancel-wait",
  site: "handoff",
  async run(h) {
    const started = Date.now();
    await h.begin(`await (async () => { ${invokeScript("web:ox-handoff-cancel.localhost:login")} })();
const pages = (await ox.web.browser.pages({ purpose: "Find delayed handoff page" })).pages.filter(page => page.owned);
await ox.web.browser.showPage({ purpose: "Wait for delayed page", pageId: pages[0].pageId });`, true);
    const counters = h.site("handoff").counters;
    const deadline = Date.now() + 10_000;
    while (!counters["cancel.starts"] && Date.now() < deadline) await Bun.sleep(100);
    assert.equal(counters["cancel.starts"], 1, "delayed navigation did not start");
    let waiting = false;
    while (!waiting && Date.now() < deadline) {
      const logs = await h.ox(["host", "logs", "--grep", "Service.handoff waiting domain=ox-handoff-cancel.localhost", "--since", new Date(started).toISOString(), "--limit", "10"]);
      waiting = logs.length > 0;
      if (!waiting) await Bun.sleep(100);
    }
    assert.ok(waiting, "presentation did not enter its navigation wait");
    await h.ox(["conversation", "stop"], { conversation: true });
    await h.idle();
    assert.equal((await h.turn("return { recovered: true };")).recovered, true);
    assert.equal(counters["cancel.dispatches"], 1, "stopping the run replayed login");
    assert.equal(counters["cancel.destinations"] ?? 0, 0, "cancellation waited for the delayed response");
    const logs = await h.ox(["host", "logs", "--grep", "Service.handoff", "--since", new Date(started).toISOString(), "--limit", "200"]);
    await writeFile(`${h.evidence}/cancel.json`, JSON.stringify({ elapsedMs: Date.now() - started, counters, logs }, null, 2));
    return "stopping during slow navigation released the wait and left the conversation usable without replay";
  },
});

type KeyboardFrame = { phase: string; keyboard: number[]; overlap: number };

async function keyboardFrames(h: Harness, since: string): Promise<KeyboardFrame[]> {
  const logs = await h.ox(["host", "logs", "--grep", "ConversationUX.keyboard ", "--since", since, "--limit", "200"]) as Array<{ seq: number; message: string }>;
  await writeFile(`${h.evidence}/keyboard-logs.json`, JSON.stringify(logs, null, 2));
  return logs.toSorted((a, b) => a.seq - b.seq).flatMap(({ message }) => {
    const match = /phase=(\w+) composer=\([^)]*\) keyboard=\(([^)]*)\) overlap=(\d+)/.exec(message);
    return match ? [{ phase: match[1]!, keyboard: match[2]!.split(",").map(Number), overlap: Number(match[3]) }] : [];
  });
}

async function settledKeyboard(h: Harness, since: string, accept: (frame: KeyboardFrame) => boolean): Promise<KeyboardFrame> {
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    const settled = (await keyboardFrames(h, since)).filter(frame => frame.phase === "didChange").at(-1);
    if (settled && accept(settled)) return settled;
    await Bun.sleep(300);
  }
  throw new Error(`Keyboard did not settle; the case needs the software keyboard (Simulator hardware keyboard disconnected): ${JSON.stringify((await keyboardFrames(h, since)).at(-1) ?? null)}`);
}

handoffCases.push({
  name: "handoff-keyboard",
  site: "handoff",
  async run(h) {
    const udid = await h.ios.udid();
    const tap = (x: number, y: number) => run(["idb", "ui", "tap", String(Math.round(x)), String(Math.round(y)), "--udid", udid], { capture: true });
    await h.begin(`await (async () => { ${invokeScript("web:ox-handoff-control.localhost:login")} })();
const pages = (await ox.web.browser.pages({ purpose: "Find prepared handoff page" })).pages.filter(page => page.owned);
return { value: await ox.web.browser.showPage({ purpose: "Show keyboard handoff", pageId: pages[0].pageId }) };`, true);
    const doneID = await h.waitMatching(/^conversation\.service\.login\..+\.done$/, 20_000);
    try {
      const frame = async (pattern: RegExp) => elements(await h.ios.describe()).find(element => pattern.test(element.AXUniqueId ?? ""))?.frame;
      const done = (await frame(new RegExp(`^${doneID.replaceAll(".", "\\.")}$`)))!;
      const input = (await frame(/^conversation\.input$/))!;
      if (input.y < done.y + 300) {
        await tap(200, done.y + done.height + 20);
        await Bun.sleep(1_000);
      }
      for (let attempt = 0; attempt < 4; attempt++) {
        const header = (await frame(/^serviceInspector\.open\./))!;
        const center = Math.round(header.y + header.height / 2);
        if (Math.abs(center - 150) < 30) break;
        await run(["idb", "ui", "swipe", "150", String(center), "150", "150", "--duration", "1.0", "--udid", udid], { capture: true });
        await Bun.sleep(800);
      }
      await h.screenshot("handoff-keyboard-ready");
      const webSince = new Date().toISOString();
      const field = await h.webField("Email");
      await tap(field.x, field.y);
      await Bun.sleep(1_000);
      await h.screenshot("handoff-keyboard-web");
      const web = await settledKeyboard(h, webSince, frame => frame.keyboard[3]! >= 200 && frame.keyboard[1]! < field.y + 200);
      const [x, y, width] = web.keyboard as [number, number, number];
      const dismissSince = new Date().toISOString();
      await tap(x + width - 42, y + 34);
      await settledKeyboard(h, dismissSince, frame => frame.keyboard[1]! > y + 100);
      const composerSince = new Date().toISOString();
      await h.ios.tap({ id: "conversation.input" }, { stable: 300 });
      await Bun.sleep(1_500);
      const composer = await settledKeyboard(h, composerSince, frame => frame.keyboard[3]! >= 200);
      await h.screenshot("handoff-keyboard");
      const resyncs = await h.ox(["host", "logs", "--grep", "ConversationUX.keyboardGuide", "--since", webSince, "--limit", "20"]) as unknown[];
      assert.equal(composer.overlap, 0, `keyboard covers the composer after web input: ${JSON.stringify(composer)}`);
      return `composer clear of keyboard after web input; web keyboard=${web.keyboard[3]}pt, composer keyboard=${composer.keyboard[3]}pt, guide resyncs=${resyncs.length}`;
    } finally {
      await h.tapMatching(/^conversation\.service\.login\..+\.cancel$/);
      assert.deepEqual(h.lastResult(await h.idle()), { value: { status: "cancelled" } });
    }
  },
});
