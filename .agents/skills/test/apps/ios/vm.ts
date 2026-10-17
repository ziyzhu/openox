import { strict as assert } from "node:assert";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { run } from "../../../../lib.ts";
import { qaCommand } from "../../../setup/scripts/qa-config.ts";
import { claimSimulator, requireSimulator } from "../../../setup/scripts/simulator.ts";
import { contracts } from "../../../../../packages/agent/src/functions/contracts";

const config = qaCommand({ usage: "Usage: bun .agents/skills/test/apps/ios/vm.ts --device ox-N --host <ws-url>\nRequires a fresh installed build. Uses a new QA Profile and Mock without inference. Restores the previous Profile.", options: { host: {type:"string"} } });
if (!config.values.host) throw new Error("Pass --host explicitly");
const endpoint = new URL(config.values.host);
if (!["ws:","wss:"].includes(endpoint.protocol) || Number(endpoint.port) !== config.debugPort) throw new Error("Use the assigned simulator port");
const release = claimSimulator(config.device);
const evidence = await mkdtemp(join(tmpdir(),"ox-vm-integration-"));
const functionNames = Object.keys(contracts);
const cli = ["bun","apps/cli/src/ox.ts","--host",endpoint.href];
async function call(args: string[], chat?: string) {
  const result = await run([...cli,...chat ? ["--conversation",chat] : [],...args,"--json"],{capture:true});
  return JSON.parse(result.stdout);
}
let previous: string | undefined;
try {
  assert.ok(await requireSimulator(config.device),"Boot the reserved QA simulator first");
  const active = await call(["conversation","inspect"]);
  assert.ok(!active?.isBusy && !active?.pendingPrompt,"Do not interrupt active work");
  const profiles = await call(["profile","list"]);
  previous = profiles.profiles.find((profile: {active:boolean})=>profile.active)?.id;
  const name = "VM Integration " + Date.now();
  const created = await call(["profile","create","--name",name]);
  await call(["profile","select",created.profile.id]);
  const schema = await call(["vm","functions"]);
  assert.deepEqual(schema,contracts,"Stub catalog drift: export vm functions from the changed build and review the contract changes");
  for (const temporary of [true,false,true]) {
    const chat = await call(["conversation","new",...temporary ? ["--temporary"] : [],"--provider","mock","--model","mock"]);
    const source = `
      const names = ${JSON.stringify(functionNames)};
      for (const name of names) {
        const parts = name.split('.').slice(1); let target = ox;
        for (const part of parts) { if (typeof target.help !== 'function') throw Error('Missing namespace help: '+name); target = target[part]; }
        if (typeof target.help !== 'function' || typeof target.help() !== 'string') throw Error('Missing function help: '+name);
      }
      const providerSchema = ox.provider.schema();
      if (providerSchema instanceof Promise || !Array.isArray(providerSchema.anyOf)) throw Error('Provider schema must be synchronous and complete');
      providerSchema.anyOf.length = 0;
      if (!ox.provider.schema().anyOf.length) throw Error('Provider schema mutation escaped');
      const before = await ox.fs.read({path:'MEMORY.md',purpose:'Read QA memory'});
      const parallel = await Promise.all([ox.app.profile({purpose:'Inspect QA Profile'}),ox.fs.read({path:'SOUL.md',purpose:'Read QA soul'})]);
      const invalid = [];
      for (const invoke of [()=>ox.fs.read({path:17,purpose:'Check schema'}),()=>ox.web.browser.navigate({url:17,purpose:'Check nested schema'})]) {
        try {await invoke(); throw Error('Invalid input accepted')} catch(e) {if(e.code!=='invalid_argument') throw e; invalid.push(JSON.parse(JSON.stringify(e)));}
      }
      let denied;
      try {await ox.fs.write({path:'skills/manage-providers/SKILL.md',content:'forbidden',purpose:'Verify read-only mount'}); throw Error('System skill write accepted')}
      catch(e) {if(e.code!=='permission_denied') throw e; denied=JSON.parse(JSON.stringify(e));}
      return {count:names.length,profile:parallel[0],memory:before,denied,invalid,aliases:ox.app.setModel===ox.conversation.setModel};
    `;
    const result = await call(["vm","eval","--script",source],chat.chatId);
    await writeFile(join(evidence,`${temporary ? "temporary" : "saved"}-${chat.chatId}.json`),JSON.stringify(result,null,2),{mode:0o600});
    assert.equal(result.value.profile.name,name);
    assert.equal(result.value.count,functionNames.length);
    assert.equal(result.value.aliases,true);
    assert.equal(result.value.memory.truncated,false);
    assert.equal(result.value.invalid.length,2);
    await call(["profile","select",previous!]);
    await assert.rejects(call(["vm","call","ox.fs.read","--args",JSON.stringify({path:"MEMORY.md",purpose:"Reject stale Profile access"})],chat.chatId));
    await call(["profile","select",created.profile.id]);
  }
  console.log(`PASS VM contracts, all namespace/function help, temporary/saved filesystem reads, parallel calls, Profile switching, validation, error serialization, read-only skill protection, aliases. Evidence: ${evidence}`);
} finally {
  try { if (previous) await call(["profile","select",previous]); }
  finally { release(); }
}
