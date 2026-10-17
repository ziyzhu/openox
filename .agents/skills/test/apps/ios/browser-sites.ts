import assert from "node:assert/strict";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { run } from "../../../../lib.ts";
import { qaCommand } from "../../../setup/scripts/qa-config.ts";
import { claimSimulator, requireSimulator } from "../../../setup/scripts/simulator.ts";

const qa = qaCommand({
  usage: "bun .agents/skills/test/apps/ios/browser-sites.ts --device ox-N --conversation <idle-Mock-QA-conversation>\nRequires a fresh installed build and public HTTPS. Answers Browser site prompts with Approve or Deny only; never changes policies.",
  options: { chat: { type: "string" } },
});
if (!qa.values.chat) throw new Error("Pass an idle Mock QA conversation");
const target = ["bun", "apps/cli/src/ox.ts", "--host", qa.debugEndpoint, "--conversation", qa.values.chat];
const evidence = await mkdtemp(join(tmpdir(), "ox-browser-sites-"));
let sequence = 0;
async function json(args: string[]) {
  const result = await run([...target, ...args, "--json"], { capture: true });
  await writeFile(join(evidence, `${++sequence}.json`), JSON.stringify({ args, ...result }, null, 2) + "\n", { mode: 0o600 });
  return JSON.parse(result.stdout);
}
async function execute(script: string, answers: string[]) {
  const before = (await json(["conversation", "inspect", "--messages"])).messages.length;
  await json(["conversation", "send", `execute\n${script}`, "--no-wait"]);
  const prompts: string[] = [];
  for (let attempt = 0; attempt < 300; attempt++) {
    const state = await json(["conversation", "inspect", "--pending"]);
    if (state.pendingPrompt) {
      const answer = answers[prompts.length];
      assert.ok(answer, `Unexpected prompt: ${state.pendingPrompt.prompt}`);
      prompts.push(state.pendingPrompt.prompt);
      await json(["conversation", "respond", answer, "--prompt", state.pendingPrompt.id]);
    } else if (!state.isBusy && attempt > 0) {
      const messages = (await json(["conversation", "inspect", "--messages"])).messages.slice(before);
      const result = messages.find((message: any) => message.toolResult)?.toolResult;
      assert.ok(result, "Missing execute result");
      assert.equal(prompts.length, answers.length, "Expected prompts were not shown");
      return { prompts, isError: result.isError === true, text: result.content.map((part: any) => part.text?.text ?? "").join("") };
    }
    await Bun.sleep(200);
  }
  throw new Error("Execution did not settle");
}
const title = (site: string) => (prompt: string) => assert.ok(prompt.startsWith(`Browser - ${site}\n`), prompt);
const release = claimSimulator(qa.device);
try {
  assert.ok(await requireSimulator(qa.device), "Boot the reserved QA simulator first");
  const idle = await json(["conversation", "inspect"]);
  assert.ok(!idle.isBusy && !idle.pendingPrompt, "Do not interrupt active work");
  for (const site of ["example.com", "example.org"]) {
    const policy = await json(["vm", "call", "ox.app.actionPolicies", "--args", JSON.stringify({ purpose: "Check Browser site policy", action: `ox.web.browser:${site}` })]);
    assert.equal(policy.value.resolved.policy, "ask", `Reset the ${site} Browser site policy to Ask first`);
  }
  const read = "await ox.web.browser.navigate({ purpose: 'Open site', url: 'https://example.com/' }); return await ox.web.browser.executeScript({ purpose: 'Read title', script: 'return document.title' });";

  const denied = await execute(read, ["Deny"]);
  denied.prompts.forEach(title("example.com"));
  assert.ok(denied.isError && denied.text.includes("permission_denied"), denied.text);

  const approved = await execute(read, ["Approve"]);
  approved.prompts.forEach(title("example.com"));
  assert.ok(!approved.isError && approved.text.includes("Example Domain"), approved.text);

  const otherSite = await execute("await ox.web.browser.navigate({ purpose: 'Open site', url: 'https://example.org/' }); return await ox.web.browser.exportPdf({ purpose: 'Export page' });", ["Deny"]);
  otherSite.prompts.forEach(title("example.org"));
  assert.ok(otherSite.isError && otherSite.text.includes("permission_denied"), otherSite.text);

  const ungated = await execute("await ox.web.browser.navigate({ purpose: 'Open site', url: 'https://example.com/' }); return await ox.web.browser.getPageInfo({ purpose: 'Inspect page' });", []);
  assert.ok(!ungated.isError && ungated.text.includes("example.com"), ungated.text);

  const suffix = await execute("return await ox.web.browser.injectScript({ purpose: 'Inject script', domains: ['com'], script: 'void 0' });", []);
  assert.ok(suffix.isError && suffix.text.includes("registrable domains"), suffix.text);

  const injected = await execute("return await ox.web.browser.injectScript({ purpose: 'Inject script', domains: ['www.example.com', 'example.org'], script: 'void 0' });", ["Approve", "Deny"]);
  title("example.com")(injected.prompts[0]!);
  title("example.org")(injected.prompts[1]!);
  assert.ok(injected.isError && injected.text.includes("permission_denied"), injected.text);

  const capture = await execute(`
    await ox.web.browser.navigate({ purpose: 'Open site', url: 'https://example.com/' });
    await ox.web.browser.startCapture({ purpose: 'Capture traffic', includeBodies: true });
    await ox.web.browser.executeScript({ purpose: 'Fetch page', script: 'await fetch(location.href); await new Promise(resolve => setTimeout(resolve, 500)); return true' });
    const listed = await ox.web.browser.listCapturedEvents({ purpose: 'List traffic' });
    const event = listed.events.find(event => event.kind === 'fetch');
    const detail = await ox.web.browser.readCapturedEvent({ purpose: 'Read traffic', id: event.id });
    await ox.web.browser.stopCapture({ purpose: 'Stop capture', discard: true });
    return { listedSite: event.site, listedBody: 'responseBody' in event, site: detail.site, body: typeof detail.responseBody };
  `, ["Approve", "Approve"]);
  capture.prompts.forEach(title("example.com"));
  assert.deepEqual(JSON.parse(capture.text), { listedSite: "example.com", listedBody: false, site: "example.com", body: "string" });

  console.log(`PASS Browser site approval: deny and approve per site, exported pages, ungated page info, public-suffix rejection, per-domain script injection, captured bodies. Evidence: ${evidence}`);
} finally {
  release();
}
