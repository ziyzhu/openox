import { expect, test } from "bun:test";
import { createModels } from "@earendil-works/pi-ai/models";
import { fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai/providers/faux";
import { EvalRuntime } from "../evals/runtime";
import { execute } from "../evals/execute";
import { catalog } from "../evals/stubs";
import { cases } from "../../../.agents/skills/evals/scripts/cases/index";
import { fixtureTemplate, validateFixture } from "../../../.agents/skills/evals/scripts/fixtures";
import { runCase } from "../../../.agents/skills/evals/scripts/ox";
import { score } from "../../../.agents/skills/evals/scripts/scoring";
import type { EvalSnapshot } from "../../../.agents/skills/evals/scripts/types";

const options = { qaProfile: "EvalQA", choices: true, humanWaitMs: 0 };
async function fixture(sources: string[], stubs = {}) {
  const models = createModels();
  const faux = fauxProvider({ provider: "fixture", models: [{ id: "controlled" }], tokensPerSecond: 100000 });
  faux.setResponses([...sources.map((source, index) => fauxAssistantMessage([{ type: "toolCall", id: `call-${index}`, name: "execute", arguments: { source } }], { stopReason: "toolUse" })), fauxAssistantMessage([{ type: "text", text: "The active Profile is EvalQA in local storage." }])]);
  models.setProvider(faux.provider);
  return EvalRuntime.open("fixture", "controlled", stubs, "EvalQA", models);
}

test("production agent loop executes stubbed ox calls and independent smoke observations", async () => {
  const testCase = cases.find(test => test.id === "app-profile-success")!;
  const binding = validateFixture(fixtureTemplate([testCase], "EvalQA")).cases[testCase.id]!;
  const runtime = await fixture(["console.log(await ox.app.profile({purpose:'Inspect Profile'}));"]);
  try {
    const response = await runCase(runtime, "fixture", "controlled", testCase, binding, 15000, options);
    expect(response.errors).toEqual([]);
    const checks = score(testCase, binding, response);
    expect(checks.filter(check => !check.passed)).toEqual([]);
    expect(response.before?.values.profile).toEqual({ name: "EvalQA", storage: "local" });
    expect(response.logScope).toBe("stub-run");
    expect(response.snapshot?.messages.some(message => message.toolResult?.content.some(block => block.text?.text.includes("EvalQA")))).toBe(true);
  } finally { await runtime.close(); }
}, 20000);

test("real execute loop preserves filesystem state, errors, contract validation and denied writes", async () => {
  const runtime = await fixture([
    "console.log(await ox.fs.write({path:'note.txt',content:'before',purpose:'Write note'}));",
    "console.log(await ox.fs.edit({path:'note.txt',edits:[{oldText:'before',newText:'after'}],purpose:'Edit note'}));",
    "console.log(await ox.fs.read({path:'note.txt',purpose:'Read note'}));",
    "try {await ox.app.profile({purpose:'Read',unknown:true})} catch(e) {console.log(e.code)}; try {await ox.fs.delete({path:'note.txt',purpose:'Delete'})} catch(e) {console.log(e.code)}",
  ], { denied: ["ox.fs.delete"] });
  try {
    const conversation = await runtime.request<{ conversationId: string }>(["conversation", "new", "--temporary"]);
    await runtime.request(["conversation", "send", "Edit a note"], conversation.conversationId);
    const snapshot = await runtime.request<EvalSnapshot>(["conversation", "inspect"], conversation.conversationId);
    const receipts = snapshot.blocks.flatMap(block => block.kind.trace?.entries ?? []).map(entry => entry.invocation!);
    expect(receipts.slice(0, 3).every(receipt => receipt.outcome.succeeded), JSON.stringify(receipts)).toBe(true);
    expect(receipts[3]?.outcome.failed).toMatchObject({ code: "invalid_argument" });
    expect(receipts[4]?.outcome.failed).toMatchObject({ code: "permission_denied" });
    const observed = await runtime.request<{value:{text:string}}>(["vm", "call", "ox.fs.read", "--args", JSON.stringify({path:"note.txt",purpose:"Observe"})], conversation.conversationId);
    expect(observed.value.text).toBe("after");
    const fresh = await runtime.request<{conversationId:string}>(["conversation","new","--temporary"]);
    expect((await runtime.request<EvalSnapshot>(["conversation","inspect"],fresh.conversationId)).messages).toEqual([]);
  } finally { await runtime.close(); }
}, 20000);

test("stub state transitions commit only after valid output and remain isolated across runs", async () => {
  const stubs = { state: { language: { selection: "en", locale: "en" } }, functions: {
    "ox.app.language": [{result:{$state:"language"}}],
    "ox.app.setLanguage": [{args:{selection:"zh-Hans"}, result:{selection:"zh-Hans",locale:"zh-Hans",changed:true},set:{language:{selection:"zh-Hans",locale:"zh-Hans"}}}],
  } };
  const runtime = await fixture(["await ox.app.setLanguage({selection:'zh-Hans',purpose:'Set language'}); console.log(await ox.app.language({purpose:'Verify'}));"], stubs);
  const other = await fixture([], stubs);
  try {
    const conversation = await runtime.request<{conversationId:string}>(["conversation","new"]);
    await runtime.request(["conversation","send","Use Chinese"],conversation.conversationId);
    expect(runtime.stubs.state.language).toEqual({selection:"zh-Hans",locale:"zh-Hans"});
    expect(other.stubs.state.language).toEqual({selection:"en",locale:"en"});
    expect(()=>runtime.stubs.call("ox.app.setLanguage",{selection:"en",purpose:"Unsupported"})).toThrow("No prepared stub");
  } finally { await runtime.close(); await other.close(); }
}, 20000);

test("execute exposes namespace and function help without process, network, or dynamic-code access", async () => {
  const calls: string[] = [];
  const result = await execute("console.log(typeof process, typeof fetch, typeof Bun); console.log(ox.web.browser.help()); console.log(ox.fs.read.help()); try {console.log(ox.fs.read.constructor('return process')())} catch(e) {console.log(e.name)}", async name => {calls.push(name);return null;});
  expect(result).toContain("undefined undefined undefined");
  expect(result).toContain("ox.web.browser.navigate");
  expect(result).toContain("inputSchema");
  expect(result).toContain("EvalError");
  expect(calls).toEqual([]);
  expect(Object.keys(catalog)).toHaveLength(99);
});

test("cancellation terminates runaway execute code without a Host or simulator", async () => {
  const controller = new AbortController();
  const timer = setTimeout(()=>controller.abort(),100);
  try { await expect(execute("while(true) {}",async()=>null,controller.signal)).rejects.toThrow(); }
  finally {clearTimeout(timer);}
}, 3000);

for (const name of ["provider", "repository", "schedule"]) {
  test(`production loop completes ${name} smoke with realistic state and preserved memory`, async () => {
    const testCase = cases.find(test => test.id === `${name}-list-success`)!;
    const binding = validateFixture(fixtureTemplate([testCase],"EvalQA")).cases[testCase.id]!;
    const runtime = await fixture([`console.log(await ox.${name}.list({purpose:'Inspect current state'}));`]);
    try {
      const response = await runCase(runtime,"fixture","controlled",testCase,binding,15000,options);
      expect(response.errors).toEqual([]);
      expect(score(testCase,binding,response).filter(check=>!check.passed)).toEqual([]);
    } finally {await runtime.close();}
  });
}

test("fabricated completion cannot pass without actual tool receipts", async()=>{
  const testCase=cases.find(test=>test.id==="app-profile-success")!;
  const binding=validateFixture(fixtureTemplate([testCase],"EvalQA")).cases[testCase.id]!;
  const runtime=await fixture([]);
  try {
    const response=await runCase(runtime,"fixture","controlled",testCase,binding,15000,options);
    expect(score(testCase,binding,response).some(check=>!check.passed && check.detail.includes("actual receipts"))).toBe(true);
  } finally {await runtime.close();}
});

test("invalid stub output cannot mutate state and failed calls remain observable in the agent loop",async()=>{
  const runtime=await fixture(["try {await ox.app.setLanguage({selection:'zh-Hans',purpose:'Change language'})} catch(e) {console.log(e.message)}"],{state:{language:"en"},functions:{"ox.app.setLanguage":[{result:{changed:"wrong-type"},set:{language:"zh-Hans"}}]}});
  try {
    const conversation=await runtime.request<{conversationId:string}>(["conversation","new"]);
    await runtime.request(["conversation","send","Set Chinese"],conversation.conversationId);
    expect(runtime.stubs.state.language).toBe("en");
    const snapshot=await runtime.request<EvalSnapshot>(["conversation","inspect"],conversation.conversationId);
    expect(snapshot.blocks[0]!.kind.trace!.entries[0]!.invocation!.outcome.failed).toMatchObject({code:"operation_failed"});
  } finally {await runtime.close();}
});

test("model loop reads actual bundled System skills through the stub filesystem",async()=>{
  const runtime=await fixture(["console.log(await ox.fs.read({path:'skills/manage-providers/SKILL.md',purpose:'Read provider guidance'}));"]);
  try {
    const conversation=await runtime.request<{conversationId:string}>(["conversation","new","--temporary"]);
    await runtime.request(["conversation","send","Read provider setup instructions"],conversation.conversationId);
    const snapshot=await runtime.request<EvalSnapshot>(["conversation","inspect"],conversation.conversationId);
    const content=snapshot.blocks[0]!.kind.trace!.entries[0]!.invocation!.outcome.succeeded?._0 as {text:string};
    expect(content.text.trim()).toBe((await Bun.file(new URL("../skills/manage-providers/SKILL.md",import.meta.url)).text()).trim());
  } finally {await runtime.close();}
});

test("fresh conversations see changed memory while earlier prompts stay frozen and temporary writes fail",async()=>{
  const runtime=await fixture(["await ox.fs.write({path:'MEMORY.md',content:'Updated preference',purpose:'Remember preference'});"],{files:{"MEMORY.md":"Original preference"}});
  try {
    const first=await runtime.request<{conversationId:string}>(["conversation","new"]);
    await runtime.request(["conversation","send","Remember updated preference"],first.conversationId);
    const fresh=await runtime.request<{conversationId:string}>(["conversation","new","--temporary"]);
    expect((await runtime.request<EvalSnapshot>(["conversation","inspect"],first.conversationId)).memory).toBe("Original preference");
    expect((await runtime.request<EvalSnapshot>(["conversation","inspect"],fresh.conversationId)).memory).toBe("Updated preference");
    await expect(runtime.request(["vm","call","ox.fs.write","--args",JSON.stringify({path:"MEMORY.md",content:"Forbidden",purpose:"Test temporary scope"})],fresh.conversationId)).rejects.toThrow("Temporary conversations");
  } finally {await runtime.close();}
});
