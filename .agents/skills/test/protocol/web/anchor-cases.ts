import { strict as assert } from "node:assert";
import { writeFile } from "node:fs/promises";
import { run } from "../../../../lib.ts";
import { elements } from "../../../setup/scripts/ios.ts";
import { invokeScript, type Case } from "./cases.ts";
import type { Harness } from "./harness.ts";

async function composerSend(h: Harness, text: string) {
  await h.ios.tap({ id: "conversation.input" }, { stable: 300 });
  await Bun.sleep(500);
  await h.ios.text(text);
  await h.ios.tap({ id: "conversation.send" }, { stable: 300 });
  await h.idle();
  await Bun.sleep(1_000);
}

async function lastUserBubbleAtEnd(h: Harness) {
  const udid = await h.ios.udid();
  let previous = Number.NaN;
  for (let attempt = 0; attempt < 12; attempt++) {
    const bubble = elements(await h.ios.describe()).filter(element => element.AXUniqueId === "conversation.message.user").at(-1)?.frame;
    if (!bubble) throw new Error("No user message in the transcript");
    if (Math.abs(bubble.y - previous) < 1) return bubble;
    previous = bubble.y;
    await run(["idb", "ui", "swipe", "396", "600", "396", "150", "--duration", "0.2", "--udid", udid], { capture: true });
    await Bun.sleep(900);
  }
  throw new Error("Transcript did not come to rest at its end");
}

export const anchorCases: Case[] = [{
  name: "handoff-anchor-floor",
  site: "handoff",
  async run(h) {
    await composerSend(h, "1");
    const since = new Date().toISOString();
    await h.begin(`await (async () => { ${invokeScript("web:ox-handoff-control.localhost:login")} })();
const pages = (await ox.web.browser.pages({ purpose: "Find prepared handoff page" })).pages.filter(page => page.owned);
return { value: await ox.web.browser.showPage({ purpose: "Show anchored handoff", pageId: pages[0].pageId }) };`, true);
    await h.ios.wait({ id: "conversation.scrollToBottom" }, { timeout: 20_000, stable: 500 });
    await h.ios.tap({ id: "conversation.scrollToBottom" }, { stable: 300 });
    await Bun.sleep(1_500);
    const done = await h.waitMatching(/^conversation\.service\.login\..+\.done$/, 60_000);
    await Bun.sleep(1_500);
    const frame = elements(await h.ios.describe()).find(element => element.AXUniqueId === done)!.frame!;
    await run(["idb", "ui", "tap", String(Math.round(frame.x + frame.width / 2)), String(Math.round(frame.y + frame.height / 2)), "--udid", await h.ios.udid()], { capture: true });
    assert.deepEqual(h.lastResult(await h.idle()), { value: { status: "completed" } });
    const logs = await h.ox(["host", "logs", "--grep", "ConversationUX.floor ", "--since", since, "--limit", "50"]) as Array<{ message: string }>;
    await writeFile(`${h.evidence}/anchor-floor-logs.json`, JSON.stringify(logs, null, 2));
    const hold = logs.map(({ message }) => /phase=hold .*floor=(\d+) contentFloor=(\d+)/.exec(message)).find(Boolean);
    assert.ok(hold, "ending the handoff did not hold the anchor floor; the case no longer exercises the hold");
    const [held, resting] = [Number(hold[1]), Number(hold[2])];
    assert.ok(held > resting + 200, `held floor ${held} does not exceed the viewport floor ${resting}; the case no longer exercises a stale hold`);
    await composerSend(h, "0");
    const bubble = await lastUserBubbleAtEnd(h);
    await h.screenshot("handoff-anchor-floor");
    assert.ok(bubble.y >= 100 && bubble.y <= 260,
      `short reply's turn does not end at the anchor floor: user message y=${Math.round(bubble.y)} at the transcript end (held floor ${held}, viewport floor ${resting})`);
    return `held floor ${held} > viewport floor ${resting}; next short turn ends at its anchor (user message y=${Math.round(bubble.y)})`;
  },
}];
