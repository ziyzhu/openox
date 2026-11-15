import { strict as assert } from "node:assert";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { Case } from "./cases.ts";
import { invokeScript } from "./cases.ts";
import type { Harness, Responder } from "./harness.ts";
import { automationActions } from "./sites/automation.ts";

const approveFixture: Responder = prompt => {
  if (/fixture|repositories\/local|Write a file|Edit a file|Select.*source/i.test(prompt.prompt) && prompt.options.includes("Approve")) return "Approve";
  return undefined;
};

async function prepare(h: Harness, host: string) {
  const service = h.site("automation").services(h.fixtures.origin).find(service => service.manifest.domain === host)!;
  await h.turn(`
await ox.fs.read({purpose:"Read authoring workflow",path:"skills/evolve/SKILL.md"});
const root = ${JSON.stringify(`repositories/local/web/${host}`)};
await ox.fs.write({purpose:"Write fixture manifest",path:root+"/service.json",content:${JSON.stringify(JSON.stringify(service.manifest))}});
await ox.fs.write({purpose:"Embed fixture automation",path:root+"/actions.js",content:${JSON.stringify(automationActions(host))}});
const indexPath = "repositories/local/repository.json";
const index = JSON.parse((await ox.fs.read({purpose:"Read fixture registry",path:indexPath})).text);
if (!index.services.includes(${JSON.stringify(`web:${host}`)})) {
  index.services.push(${JSON.stringify(`web:${host}`)});
  await ox.fs.write({purpose:"Register fixture service",path:indexPath,content:JSON.stringify(index)});
}
await ox.service.validate({purpose:"Validate fixture service",domain:${JSON.stringify(host)}});
return {written:true};`, approveFixture);
  await h.ox(["service", "sync"]);
  return h.turn(`
const root = ${JSON.stringify(`repositories/local/web/${host}`)};
const conflicts = await ox.repository.conflicts({purpose:"Inspect fixture sources",service:${JSON.stringify(host)}});
const local = conflicts.conflicts.flatMap(conflict=>conflict.candidates).find(candidate=>candidate.path===root);
if (!local) throw new Error("New Local fixture source is missing from conflicts");
await ox.repository.resolve({purpose:"Select fixture source",service:${JSON.stringify(host)},repository:local.repository});
return {prepared:true};`, approveFixture);
}

async function sourceBoundary(h: Harness, host: string) {
  return h.turn(`
const path = ${JSON.stringify(`repositories/local/web/${host}/actions.js`)};
const purpose = "Check fixture source boundary";
const original = await ox.fs.read({purpose,path});
if (original.truncated) throw new Error("Unexpected fixture source truncation");
await ox.fs.edit({purpose,path,edits:[{oldText:"timeout = 5000",newText:"timeout = 4500"}]});
const edited = (await ox.fs.read({purpose,path})).text;
await ox.service.validate({purpose,domain:${JSON.stringify(host)}});
await ox.fs.write({purpose,path,content:edited});
const rewritten = (await ox.fs.read({purpose,path})).text;
await ox.fs.write({purpose,path,content:rewritten + "\\nconst broken = ;"});
let invalidRejected = false;
try { await ox.service.validate({purpose,domain:${JSON.stringify(host)}}); } catch { invalidRejected = true; }
await ox.fs.write({purpose,path,content:rewritten});
await ox.service.validate({purpose,domain:${JSON.stringify(host)}});
const pages = [];
let offset = 1;
do {
 const part=await ox.fs.read({purpose,path,offset,limit:7});
 pages.push(part.text);
 offset=part.nextOffset;
} while(offset!==null);
let bytes="", byteOffset=0;
do {
 const part=await ox.fs.read({purpose,path,byteOffset});
 bytes+=part.text;
 byteOffset=part.nextByteOffset;
} while(byteOffset!==null);
const boundary=original.text.indexOf("window.ox.install");
if(boundary<0) throw new Error("Fixture service body is missing");
const prefix=original.text.slice(0,boundary);
const serviceStartLine=prefix.split(String.fromCharCode(10)).length;
const service=await ox.fs.read({purpose,path,offset:serviceStartLine});
const readMilliseconds={full:[],targeted:[]};
for(let sample=0;sample<6;sample++) {
 for(const kind of sample%2?["full","targeted"]:["targeted","full"]) {
  const start=Date.now();
  await ox.fs.read({purpose,path,...(kind==="targeted"?{offset:serviceStartLine}:{})});
  readMilliseconds[kind].push(Date.now()-start);
 }
}
const size=text=>encodeURIComponent(text).replace(/%[0-9A-F]{2}|[^%]/g,"x").length;
return {editable:edited.includes("timeout = 4500"),unchanged:rewritten===edited,visible:original.text.includes("function createEmbeddedAutomation"),invalidRejected,pagination:pages.join(String.fromCharCode(10))===rewritten,byteRoundTrip:bytes===rewritten,selectedOnly:!original.text.includes("const retryFetch")&&!original.text.includes("const createFetchCapture"),fullBytes:size(original.text),serviceBytes:size(service.text),helperBytes:size(prefix),serviceStartLine,readMilliseconds};`, approveFixture);
}

export const automationCases: Case[] = Object.entries({
  "ox-catalog.localhost": "automation-catalog",
  "ox-search.localhost": "automation-search",
  "ox-settings.localhost": "automation-settings",
}).map(([host, name]) => ({
  name, site: "automation",
  async run(h) {
    await prepare(h, host);
    const source = await sourceBoundary(h, host);
    for (const field of ["editable", "unchanged", "visible", "invalidRejected", "pagination", "byteRoundTrip", "selectedOnly"]) assert.equal(source[field], true, field);
    const result = await h.turn(invokeScript(`web:${host}:exercise`), approveFixture);
    if (host === "ox-catalog.localhost") assert.deepEqual(result, {names:["BasicDetails","FeaturedDetails","PremiumDetails"],featured:"two",last:"three"});
    if (host === "ox-search.localhost") assert.deepEqual(result, {text:"Results for locator fixture",clicks:1});
    if (host === "ox-settings.localhost") assert.deepEqual(result, {checked:true,changes:1,theme:"dark",biography:"Fixture profile"});
    const boundaries = await h.turn(invokeScript(`web:${host}:boundaries`), approveFixture);
    assert.equal(boundaries.dispatched, 0);
    for (const [key, value] of Object.entries(boundaries.failures)) assert.notEqual(value, "accepted", key);
    assert.match(boundaries.failures.ambiguous, /Strict locator/);
    assert.match(boundaries.failures.obscured, /obscured/);
    const benchmark = await h.turn(invokeScript(`web:${host}:benchmark`), approveFixture);
    await writeFile(join(h.evidence, `${name}-${Date.now()}-benchmark.json`), JSON.stringify({host,source,result,boundaries,benchmark},null,2));
    return `selected helper embedded and validated; 6 rejected unsafe targets; ${source.fullBytes} full / ${source.serviceBytes} targeted source bytes; ${benchmark.batches * benchmark.iterationsPerBatch} reads per implementation`;
  },
}));
