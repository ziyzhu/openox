import assert from "node:assert/strict";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { run } from "../../../../lib.ts";
import { qaCommand } from "../../../setup/scripts/qa-config.ts";
import { claimSimulator, requireSimulator } from "../../../setup/scripts/simulator.ts";

const qa = qaCommand({
  usage: "bun .agents/skills/test/apps/ios/public-web.ts --device ox-N\nRequires a fresh installed build, public DNS, and public HTTPS. Uses a new temporary Mock conversation and approves only the example.com Browser script prompt. Browser and MCP checks skip HTTP because simulator builds allow loopback HTTP; DNS-resolved MCP endpoints are not covered.",
});
const host = ["bun", "apps/cli/src/ox.ts", "--host", qa.debugEndpoint];
const evidence = await mkdtemp(join(tmpdir(), "ox-public-web-"));
let sequence = 0;
async function json(args: string[]) {
  const result = await run([...host, ...args, "--json"], { capture: true });
  await writeFile(join(evidence, `${++sequence}.json`), JSON.stringify({ args, ...result }, null, 2) + "\n", { mode: 0o600 });
  return JSON.parse(result.stdout);
}
const blocked = [
  "http://127.1/", "https://127.1/", "http://2130706433/", "https://0x7f.1/", "http://0177.0.0.1/",
  "http://localhost./", "https://localhost./", "https://127.0.0.1.nip.io/", "https://10.0.0.1.nip.io/",
  "https://[::127.0.0.1]/", "https://[::ffff:127.0.0.1]/", "https://[64:ff9b::7f00:1]/", "https://[2002:7f00:1::]/",
  "https://[fe80::1%25en0]/", "https://100.100.100.100/", "https://192.168.1.1./", "https://192.0.0.1/",
];
const fetchRejection = /url must be a public HTTP or HTTPS URL|did not resolve to only public addresses/;
const rejections: Record<string, RegExp> = {
  fetch: fetchRejection,
  attach: fetchRejection,
  browser: /requires an absolute public HTTPS URL|private-network, unresolvable, or unsupported HTTPS destination/,
  mcp: /Enter a public HTTPS MCP endpoint/,
};
const release = claimSimulator(qa.device);
try {
  assert.ok(await requireSimulator(qa.device), "Boot the reserved QA simulator first");
  const conversation = (await json(["conversation", "new", "--temporary", "--provider", "mock", "--model", "mock"])).conversationId;
  const target = ["--conversation", conversation];
  const evaluated = await json([...target, "vm", "eval", "--script", `
    const attempt = async call => { try { return { ok: true, value: await call() }; } catch (error) { return { ok: false, error: String(error.message) }; } };
    const blocked = [];
    for (const url of ${JSON.stringify(blocked)}) {
      blocked.push({ url, fetch: await attempt(() => ox.web.fetch({ url, purpose: 'Check private fetch' })),
        attach: await attempt(() => ox.fs.attach({ path: url, purpose: 'Check private attach' })),
        browser: url.startsWith('https:') ? await attempt(() => ox.web.browser.navigate({ url, purpose: 'Check private navigation' })) : null,
        mcp: url.startsWith('https:') && !url.includes('.nip.io') ? await attempt(() => ox.service.create({ kind: 'mcp', endpoint: url, purpose: 'Check private MCP' })) : null });
    }
    const fetched = await ox.web.fetch({ url: 'https://example.com/', purpose: 'Check public fetch' });
    const attached = await ox.fs.attach({ path: 'https://example.com/', purpose: 'Check public attach' });
    const navigated = await ox.web.browser.navigate({ url: 'https://example.com/', purpose: 'Check public navigation' });
    return { blocked, fetched: fetched.status, attached: attached.kind, navigated: navigated.url };
  `]);
  for (const result of evaluated.value.blocked) {
    for (const kind of ["fetch", "attach", "browser", "mcp"]) {
      const outcome = result[kind];
      if (outcome === null) continue;
      assert.equal(outcome.ok, false, `${kind} reached ${result.url}`);
      assert.match(outcome.error, rejections[kind]!, `${kind} ${result.url}: ${outcome.error}`);
    }
  }
  assert.deepEqual([evaluated.value.fetched, evaluated.value.attached, evaluated.value.navigated], [200, "text", "https://example.com/"]);

  const since = new Date().toISOString();
  const before = (await json([...target, "conversation", "inspect", "--messages"])).messages.length;
  await json([...target, "conversation", "send", `execute
await ox.web.browser.navigate({ purpose: 'Open site', url: 'https://example.com/' });
return await ox.web.browser.executeScript({ purpose: 'Add frames', script: \`
  for (const src of ['https://127.0.0.1.nip.io/qa-frame', 'https://example.org/']) {
    const frame = document.createElement('iframe'); frame.src = src; document.body.appendChild(frame);
  }
  await new Promise(resolve => setTimeout(resolve, 3000));
  return document.querySelectorAll('iframe').length;\` });`, "--no-wait"]);
  let frames: string | undefined;
  for (let attempt = 0; attempt < 300 && frames === undefined; attempt++) {
    const state = await json([...target, "conversation", "inspect", "--pending"]);
    if (state.pendingPrompt) {
      assert.ok(state.pendingPrompt.prompt.startsWith("Browser - example.com\n"), state.pendingPrompt.prompt);
      await json([...target, "conversation", "respond", "Approve", "--prompt", state.pendingPrompt.id]);
    } else if (!state.isBusy && attempt > 0) {
      const messages = (await json([...target, "conversation", "inspect", "--messages"])).messages.slice(before);
      const result = messages.find((message: any) => message.toolResult)?.toolResult;
      assert.ok(result && result.isError !== true, JSON.stringify(result));
      frames = result.content.map((part: any) => part.text?.text ?? "").join("");
    }
    await Bun.sleep(200);
  }
  assert.equal(frames, "2", "Frame script did not settle");
  const rejected: { message: string }[] = await json(["host", "logs", "--grep", "Service.navigation rejected-frame", "--since", since]);
  assert.deepEqual(rejected.map(entry => entry.message.split("url=")[1]), ["https://127.0.0.1.nip.io/qa-frame"], "Expected only the private frame to be rejected");

  console.log(`PASS public web: ${blocked.length} private, alternate-notation, and DNS-resolved hosts rejected by ox.web.fetch, ox.fs.attach, Browser navigation, and MCP endpoint validation; private subframe cancelled while a public subframe loads; public fetch, attach, and navigation succeed. Evidence: ${evidence}`);
} finally {
  release();
}
