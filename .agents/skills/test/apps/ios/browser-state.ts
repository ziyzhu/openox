import assert from "node:assert/strict";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { run } from "../../../../lib.ts";
import { qaCommand } from "../../../setup/scripts/qa-config.ts";
import { claimSimulator, requireSimulator } from "../../../setup/scripts/simulator.ts";

const qa = qaCommand({
  usage: "bun .agents/skills/test/apps/ios/browser-state.ts --device ox-N --conversation <idle-Mock-QA-conversation>\nRequires a fresh installed Debug build with loopback enabled. Uses local synthetic pages and answers only their Browser site prompts; never changes policies.",
  options: { conversation: { type: "string" } },
});
if (!qa.values.conversation) throw new Error("Pass an idle Mock QA conversation");
const target = ["bun", "apps/cli/src/ox.ts", "--host", qa.debugEndpoint, "--conversation", qa.values.conversation];
const evidence = await mkdtemp(join(tmpdir(), "ox-browser-state-"));
let sequence = 0;
async function json(args: string[]) {
  const result = await run([...target, ...args, "--json"], { capture: true });
  await writeFile(join(evidence, `${++sequence}.json`), JSON.stringify({ args, ...result }, null, 2), { mode: 0o600 });
  return JSON.parse(result.stdout);
}
async function execute(source: string, answer: "Approve" | "Deny") {
  const before = (await json(["conversation", "inspect", "--messages"])).messages.length;
  await json(["conversation", "send", `execute\n${source}`, "--no-wait"]);
  for (let attempt = 0; attempt < 300; attempt++) {
    const state = await json(["conversation", "inspect", "--pending"]);
    if (state.pendingPrompt) {
      assert.ok(state.pendingPrompt.prompt.startsWith("Browser - 127.0.0.1\n"), "Unexpected non-fixture prompt");
      await json(["conversation", "respond", answer, "--prompt", state.pendingPrompt.id]);
    } else if (!state.isBusy && attempt > 0) {
      const messages = (await json(["conversation", "inspect", "--messages"])).messages.slice(before);
      const result = messages.find((message: any) => message.toolResult)?.toolResult;
      assert.ok(result, "Missing execution result");
      return { isError: result.isError === true, text: result.content.map((part: any) => part.text?.text ?? "").join("") };
    }
    await Bun.sleep(200);
  }
  throw new Error("Fixture execution did not settle");
}

const pages: Record<string, string> = {
  "/identity": `<main>
    <label for="id-only">ID only</label><input id="id-only" value="private-value">
    <label>Name only<input name="name-only"></label>
    <label for="different-id">Different attributes</label><input id="different-id" name="different-name">
    <button>Neither attribute</button><button id="" name="">Empty attributes</button>
    <input id="item-a" name="item" aria-label="First item"><input id="item-b" name="item" aria-label="Second item">
    <input id=" spaced  id " name=" spaced  name " aria-label="Whitespace identity">
    <input type="password" value="private-password" aria-label="Password">
    <div hidden><button id="hidden-control">Hidden control</button></div>
  </main>`,
  "/dynamic": `<main id="flow" aria-busy="true"><h1>Loading record</h1>
    <label>Optional note<input name="note" value=""></label><button id="next" disabled>Next</button>
    <div role="status">Loading record</div></main><script>
    window.finishLoading = () => { const root=document.querySelector('main'); root.setAttribute('aria-busy','false'); document.querySelector('h1').textContent='Edit record'; document.querySelector('[role=status]').textContent='Record loaded'; document.querySelector('button').disabled=false; };
    document.querySelector('button').onclick = () => { history.pushState({},'', '?step=review'); document.querySelector('main').innerHTML='<h1>Review</h1><button>Confirm</button>'; };
  </script>`,
  "/notifications": `<main><h1>Delivery</h1><div role="alert">Record saved</div>
    <div role="alert">Choose a delivery method</div><input name="delivery" aria-label="Delivery method" aria-invalid="true"></main>`,
  "/effects": `<main><h1>Local draft</h1><button id="save">Save fixture</button><div role="status">Saved changes: 0</div></main>
    <script>window.effects=0; document.querySelector('button').onclick=()=>{window.effects++;document.querySelector('[role=status]').textContent='Saved changes: '+window.effects;};</script>`,
  "/limits": `<main>${Array.from({ length: 45 }, (_, index) => `<button id="choice-${index}">Choice ${index}</button>`).join("")}</main>
    <section id="long"><input id="${"i".repeat(300)}" name="${"n".repeat(300)}" aria-label="Long identity"></section>`,
  "/next": "<main><h1>Another document</h1><button>Done</button></main>",
};
const release = claimSimulator(qa.device);
const server = Bun.serve({
  hostname: "127.0.0.1", port: 0,
  fetch(request) {
    const content = pages[new URL(request.url).pathname];
    return new Response(content ? `<!doctype html><title>Browser state fixture</title>${content}` : "Not found", {
      status: content ? 200 : 404, headers: { "Content-Type": "text/html" },
    });
  },
});
try {
  assert.ok(await requireSimulator(qa.device), "Boot the reserved QA simulator first");
  const idle = await json(["conversation", "inspect"]);
  assert.ok(!idle.isBusy && !idle.pendingPrompt && idle.model?.id === "mock", "Use an idle Mock QA conversation");
  const origin = `http://127.0.0.1:${server.port}`;
  const denied = await execute(`await ox.web.browser.navigate({purpose:'Open local fixture',url:${JSON.stringify(origin + "/identity")}}); return await ox.web.browser.getPageState({purpose:'Verify fixture authorization'});`, "Deny");
  assert.ok(denied.isError && denied.text.includes("permission_denied"), "Use a fresh QA conversation with loopback Browser policy set to Ask");
  const result = await execute(`
    const origin=${JSON.stringify(origin)};
    const check=(value,message)=>{if(!value)throw Error(message)};
    const open=path=>ox.web.browser.navigate({purpose:'Open synthetic page',url:origin+path});
    const observe=selector=>ox.web.browser.getPageState({purpose:'Observe synthetic page',...selector?{selector}:{}});
    await open('/identity');
    const identity=await observe();
    const control=label=>identity.document.controls.find(item=>item.label===label);
    check(control('ID only').id==='id-only'&&control('ID only').name===null,'ID-only control identity missing');
    check(control('Name only').id===null&&control('Name only').name==='name-only','Name-only control identity missing');
    check(control('Different attributes').id==='different-id'&&control('Different attributes').name==='different-name','ID and name conflated');
    check(control('Neither attribute').id===null&&control('Neither attribute').name===null,'Absent attributes fabricated');
    check(control('Empty attributes').id===''&&control('Empty attributes').name==='','Empty attributes conflated with absence');
    check(identity.document.controls.filter(item=>item.name==='item').length===2,'Repeated names silently deduplicated');
    check(control('Whitespace identity').id===' spaced  id '&&control('Whitespace identity').name===' spaced  name ','Identity normalized');
    check(!JSON.stringify(identity).includes('private-value')&&!JSON.stringify(identity).includes('private-password'),'Input values leaked');
    check(!identity.document.controls.some(item=>item.id==='hidden-control'),'Hidden control leaked');
    const matches=await ox.web.browser.executeScript({purpose:'Check exact selector evidence',script:${JSON.stringify('return {byId:document.querySelectorAll("#id-only").length,byName:document.querySelectorAll(\'[name="id-only"]\').length,repeated:document.querySelectorAll(\'[name="item"]\').length};')}});
    check(matches.byId===1&&matches.byName===0&&matches.repeated===2,'Selector counter-cases wrong');
    await open('/dynamic');
    const loading=await observe('#flow');
    check(loading.document.busy&&loading.document.controls.find(item=>item.id==='next').disabled,'Loading state hidden');
    await ox.web.browser.executeScript({purpose:'Finish synthetic loading',script:'window.finishLoading(); return true;'});
    const loaded=await observe('#flow');
    check(!loaded.document.busy&&loaded.document.controls.find(item=>item.name==='note').hasValue===false,'Legitimate empty value lost');
    await ox.web.browser.executeScript({purpose:'Transition within document',script:'document.querySelector("#next").click(); return true;'});
    const review=await observe('#flow');
    check(review.pageID===loaded.pageID&&review.navigationGeneration===loaded.navigationGeneration&&review.url.endsWith('?step=review'),'SPA identity changed');
    check(review.document.headings.includes('Review')&&review.document.controls.length===1,'Review without editable fields misrepresented');
    await open('/notifications');
    const notifications=await observe();
    check(notifications.document.messages.includes('Record saved')&&notifications.document.messages.includes('Choose a delivery method'),'Notification semantics inferred');
    check(notifications.document.controls[0].invalid&&!('success' in notifications.document)&&!('error' in notifications.document),'Outcome invented');
    await open('/effects');
    let beforeError;
    try{await ox.web.browser.executeScript({purpose:'Fail before local effect',script:'throw Error("before effect")'})}catch(error){beforeError=error.message}
    const beforeEffect=await observe();
    check(beforeError&&beforeEffect.document.messages.includes('Saved changes: 0'),'Pre-effect failure changed state');
    let afterError;
    try{await ox.web.browser.executeScript({purpose:'Fail after one local effect',script:'document.querySelector("#save").click(); throw Error("after effect")'})}catch(error){afterError=error.message}
    const afterEffect=await observe();
    check(afterError&&afterEffect.document.messages.includes('Saved changes: 1'),'Uncertain effect was repeated or lost');
    await open('/limits');
    const limits=await observe('main');
    check(limits.document.truncated&&limits.document.controls.length===40,'Collection limit not reported');
    const long=await observe('#long');
    check(long.document.truncated&&long.document.controls[0].id==='i'.repeat(256)&&long.document.controls[0].name==='n'.repeat(256),'Identity limit not reported');
    const missing=await observe('#missing');
    check(!missing.document.scopeFound&&missing.document.controls.length===0,'Missing scope treated as whole page');
    await open('/next');
    const next=await observe();
    check(next.pageID===review.pageID&&next.navigationGeneration>review.navigationGeneration&&next.document.headings.includes('Another document'),'Full document replacement not identified');
    return {passed:true,identity,loading,loaded,review,notifications,beforeEffect,afterEffect,limits,long,missing,next};
  `, "Approve");
  assert.ok(!result.isError, result.text);
  assert.equal(JSON.parse(result.text).passed, true);
  console.log(`PASS Browser state counter-cases: exact identities, repeated names, loading/empty/review states, mixed alerts, uncertain effects, SPA/document navigation, privacy, scopes and limits. Evidence: ${evidence}`);
} finally {
  server.stop(true);
  release();
}
