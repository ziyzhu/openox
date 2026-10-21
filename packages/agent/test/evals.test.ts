import { expect, test } from "bun:test";
import { createModels } from "@earendil-works/pi-ai/models";
import { fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai/providers/faux";
import { EvalRuntime } from "../evals/runtime";
import { execute } from "../evals/execute";
import { catalog, type StubFixture } from "../evals/stubs";
import { evaluate } from "../../../.agents/skills/evals/scripts/arm";
import { loadCase } from "../../../.agents/skills/evals/scripts/cases";

function faux(sources: string[], reply = "The active Profile is EvalQA in local storage.") {
  const models = createModels();
  const provider = fauxProvider({ provider: "fixture", models: [{ id: "controlled" }], tokensPerSecond: 100000 });
  provider.setResponses([...sources.map((source, index) => fauxAssistantMessage([{ type: "toolCall", id: `call-${index}`, name: "execute", arguments: { source } }], { stopReason: "toolUse" })), fauxAssistantMessage([{ type: "text", text: reply }])]);
  models.setProvider(provider.provider);
  return models;
}

const open = (sources: string[], stubs: StubFixture = {}) => EvalRuntime.open("fixture", "controlled", stubs, [], faux(sources));

test("production agent loop scores a case from actual stub receipts and the final answer", async () => {
  const outcome = await evaluate(await loadCase("app-profile"), "fixture", "controlled", 15000, faux(["console.log(await ox.app.profile({purpose:'Inspect Profile'}));"]));
  expect(outcome.checks.filter(check => !check.passed)).toEqual([]);
  expect(outcome.status).toBe("pass");
  expect(outcome.metrics).toMatchObject({ modelResponses: 2, toolCalls: 1, oxCalls: 1, failedOxCalls: 0 });
  expect(outcome.turn?.systemPrompt).toContain("You are Ox");
});

test("fabricated completion fails without actual tool receipts", async () => {
  const outcome = await evaluate(await loadCase("app-profile"), "fixture", "controlled", 15000, faux([]));
  expect(outcome.status).toBe("fail");
  expect(outcome.checks.find(check => check.detail === "ox.app.profile succeeded")?.passed).toBe(false);
});

test("prompt-behavior cases distinguish asking from proceeding and absence from cross-checking", async () => {
  const asked = await evaluate(await loadCase("proceed-without-asking"), "fixture", "controlled", 15000, faux(["await ox.user.choose({purpose:'Clarify',body:'Where should I save it?',options:['Notes','Desktop']});"], "Where should I save it?"));
  expect(asked.status).toBe("fail");
  const saved = await evaluate(await loadCase("proceed-without-asking"), "fixture", "controlled", 15000, faux(["await ox.fs.write({path:'camping.md',content:'- Tent\\n- Sleeping bag',purpose:'Save list'});"], "Saved to camping.md, assuming two nights."));
  expect(saved.checks.filter(check => !check.passed)).toEqual([]);
  const search = "await ox.service.invoke({purpose:'Search mail',name:'web:mail.google.com:searchMessages',input:{query:'from:dana Q3 budget'}});";
  const absent = await evaluate(await loadCase("cross-check-empty-result"), "fixture", "controlled", 15000, faux([search], "No emails from Dana about the Q3 budget."));
  expect(absent.status).toBe("fail");
  const checked = await evaluate(await loadCase("cross-check-empty-result"), "fixture", "controlled", 15000, faux([search, "console.log(await ox.web.browser.executeScript({purpose:'Read results',script:'return 1'}));"], "Found Dana's Q3 budget review email from Oct 14."));
  expect(checked.checks.filter(check => !check.passed)).toEqual([]);
  const lookup = "await ox.service.invoke({purpose:'Find Alex',name:'web:mail.google.com:searchContacts',input:{query:'Alex'}});";
  const email = (to: string) => `await ox.service.invoke({purpose:'Send numbers',name:'web:mail.google.com:sendMessage',input:{to:'${to}',subject:'Q3 budget',body:'Revenue $4.2M'}});`;
  const guessed = await evaluate(await loadCase("ask-when-consequential"), "fixture", "controlled", 15000, faux([lookup, email("alex.rivera@gmail.example")], "Sent to Alex Rivera."));
  expect(guessed.status).toBe("fail");
  const confirmed = await evaluate(await loadCase("ask-when-consequential"), "fixture", "controlled", 15000, faux([lookup, "await ox.user.choose({purpose:'Pick recipient',body:'Which Alex?',options:['Alex Chen','Alex Rivera']});", email("alex.chen@northwind.example")], "Sent to Alex Chen."));
  expect(confirmed.checks.filter(check => !check.passed)).toEqual([]);
});

test("real execute loop preserves filesystem state, errors, contract validation and denied writes", async () => {
  const runtime = await open([
    "console.log(await ox.fs.write({path:'note.txt',content:'before',purpose:'Write note'}));",
    "console.log(await ox.fs.edit({path:'note.txt',edits:[{oldText:'before',newText:'after'}],purpose:'Edit note'}));",
    "console.log(await ox.fs.read({path:'note.txt',purpose:'Read note'}));",
    "try {await ox.app.profile({purpose:'Read',unknown:true})} catch(e) {console.log(e.code)}; try {await ox.fs.rm({path:'note.txt',purpose:'Trash'})} catch(e) {console.log(e.code)}",
  ], { denied: ["ox.fs.rm"] });
  try {
    const turn = await runtime.run("Edit a note", 15000);
    expect(turn.calls.slice(0, 3).every(call => !call.error), JSON.stringify(turn.calls)).toBe(true);
    expect(turn.calls[3]?.error).toMatchObject({ code: "invalid_argument" });
    expect(turn.calls[4]?.error).toMatchObject({ code: "permission_denied" });
    expect(await runtime.observe("ox.fs.read", { path: "note.txt" })).toMatchObject({ text: "after" });
  } finally { await runtime.close(); }
}, 20000);

test("stub state transitions commit only after valid output and remain isolated across runtimes", async () => {
  const stubs = { state: { language: { selection: "en", locale: "en" } }, functions: {
    "ox.app.language": [{ result: { $state: "language" } }],
    "ox.app.setLanguage": [{ args: { selection: "zh-Hans" }, result: { selection: "zh-Hans", locale: "zh-Hans", changed: true }, set: { language: { selection: "zh-Hans", locale: "zh-Hans" } } }],
  } };
  const runtime = await open(["await ox.app.setLanguage({selection:'zh-Hans',purpose:'Set language'}); console.log(await ox.app.language({purpose:'Verify'}));"], stubs);
  const other = await open([], stubs);
  try {
    await runtime.run("Use Chinese", 15000);
    expect(runtime.stubs.state.language).toEqual({ selection: "zh-Hans", locale: "zh-Hans" });
    expect(other.stubs.state.language).toEqual({ selection: "en", locale: "en" });
    expect(() => runtime.stubs.call("ox.app.setLanguage", { selection: "en", purpose: "Unsupported" })).toThrow("No prepared stub");
  } finally { await runtime.close(); await other.close(); }
}, 20000);

test("invalid stub output cannot mutate state and failed calls remain observable", async () => {
  const runtime = await open(["try {await ox.app.setLanguage({selection:'zh-Hans',purpose:'Change language'})} catch(e) {console.log(e.message)}"], { state: { language: "en" }, functions: { "ox.app.setLanguage": [{ result: { changed: "wrong-type" }, set: { language: "zh-Hans" } }] } });
  try {
    const turn = await runtime.run("Set Chinese", 15000);
    expect(runtime.stubs.state.language).toBe("en");
    expect(turn.calls[0]?.error).toMatchObject({ code: "operation_failed" });
  } finally { await runtime.close(); }
});

test("model loop reads actual bundled System skills and temporary conversations cannot write Profile documents", async () => {
  const runtime = await open(["console.log(await ox.fs.read({path:'skills/manage-providers/SKILL.md',purpose:'Read provider guidance'})); try {await ox.fs.write({path:'MEMORY.md',content:'Forbidden',purpose:'Remember'})} catch(e) {console.log(e.code)}"]);
  try {
    const turn = await runtime.run("Read provider setup instructions", 15000, true);
    expect((turn.calls[0]?.result as { text: string }).text.trim()).toBe((await Bun.file(new URL("../skills/manage-providers/SKILL.md", import.meta.url)).text()).trim());
    expect(turn.calls[1]?.error).toMatchObject({ code: "permission_denied" });
  } finally { await runtime.close(); }
});

test("execute exposes namespace and function help without process, network, or dynamic-code access", async () => {
  const calls: string[] = [];
  const result = await execute("console.log(typeof process, typeof fetch, typeof Bun); console.log(ox.web.browser.help()); console.log(ox.fs.read.help()); try {console.log(ox.fs.read.constructor('return process')())} catch(e) {console.log(e.name)}", async name => { calls.push(name); return null; });
  expect(result).toContain("undefined undefined undefined");
  expect(result).toContain("ox.web.browser.navigate");
  expect(result).toContain("inputSchema");
  expect(result).toContain("EvalError");
  expect(calls).toEqual([]);
  expect(Object.keys(catalog)).toHaveLength(98);
});

test("cancellation terminates runaway execute code without a Host or simulator", async () => {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 100);
  try { await expect(execute("while(true) {}", async () => null, controller.signal)).rejects.toThrow(); }
  finally { clearTimeout(timer); }
}, 3000);
