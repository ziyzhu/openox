import { strict as assert } from "node:assert";
import { writeFile } from "node:fs/promises";
import { invokeScript, type Case } from "./cases.ts";

const scenarios = ["control", "slow", "stream", "server", "client", "loop", "timeout"];

export const handoffCases: Case[] = scenarios.map(scenario => ({
  name: `handoff-${scenario}`,
  site: "handoff",
  async run(h) {
    const domain = `ox-handoff-${scenario}.localhost`;
    const started = Date.now();
    const result = await h.turn(`await (async () => { ${invokeScript(`web:${domain}:login`)} })();
const { pages } = await ox.web.browser.list({ purpose: "Find prepared handoff page" });
try { return { value: await ox.web.browser.showPage({ purpose: "Show stress handoff", pageId: pages[0].pageId }) }; }
catch (error) { return { error: error.message, code: error.code }; }`);
    const elapsedMs = Date.now() - started;
    const counters = Object.fromEntries(Object.entries(h.site("handoff").counters).filter(([key]) => key.startsWith(`${scenario}.`)).map(([key, value]) => [key.slice(scenario.length + 1), value]));
    const terminal = scenario === "loop" || scenario === "timeout";
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
      assert.equal(result.value?.status, "awaiting_user", JSON.stringify(result));
      await h.waitMatching(/^conversation\.service\.login\..+\.done$/, 20_000);
      assert.equal(counters.destinations, 1, "handoff appeared before the final destination was served");
      await h.tapMatching(/^serviceInspector\.open\./);
      await h.ios.wait({ id: "serviceHandoff.cancel" }, { timeout: 10_000, stable: 500 });
      try {
        await h.fillWeb("Email", "synthetic@fixture.test");
        await h.screenshot(`handoff-${scenario}`);
      } finally {
        await h.ios.tap({ id: "serviceHandoff.cancel" }, { stable: 300 });
        await h.idle();
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
const { pages } = await ox.web.browser.list({ purpose: "Find delayed handoff page" });
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
