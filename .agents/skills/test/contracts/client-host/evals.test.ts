import { expect, test } from "bun:test";
import { mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ROOT } from "../../../../lib.ts";
import { cases, smokeIds } from "../../../evals/scripts/cases/index";
import { fixtureTemplate, validateFixture } from "../../../evals/scripts/fixtures";
import { catalog } from "../../../../../packages/agent/evals/stubs";
import { coveredFunctions } from "../../../evals/scripts/coverage";
import { compare } from "../../../evals/scripts/compare";
import type { Report } from "../../../evals/scripts/types";

async function command(args: string[]) {
  const child = Bun.spawn([process.execPath,"--no-env-file",join(ROOT,".agents/skills/evals/scripts/runner.ts"),...args],{cwd:ROOT,stdout:"pipe",stderr:"pipe",stdin:"ignore"});
  const [code,stdout,stderr] = await Promise.all([child.exited,new Response(child.stdout).text(),new Response(child.stderr).text()]);
  return {code,stdout,stderr};
}

test("eval CLI validates the complete catalog and defaults to four stub smoke cases", async()=>{
  const result = await command(["--validate","--suite","all"]);
  expect(result.code,result.stderr).toBe(0);
  expect(result.stdout).toContain("98 functions and 4 System skills");
  const listed = await command(["--list","--json"]);
  expect(JSON.parse(listed.stdout).map((test:{id:string})=>test.id)).toEqual([...smokeIds]);
  expect(new Set(cases.flatMap(coveredFunctions))).toEqual(new Set(Object.keys(catalog)));
  const help = await command(["--help"]);
  expect(help.stdout).not.toContain("--host");
  expect(help.stdout).toContain("No Host or simulator");
});

test("generated smoke fixture validates without a Host and malformed or incomplete bindings fail",async()=>{
  const directory = await mkdtemp(join(tmpdir(),"ox-stub-fixture-"));
  try {
    const output=join(directory,"fixture.json");
    expect((await command(["--template","--qa-profile","EvalQA","--output",output])).code).toBe(0);
    expect((await stat(output)).mode & 0o777).toBe(0o600);
    expect((await command(["--validate","--fixture",output])).code).toBe(0);
    const fixture=fixtureTemplate(cases.filter(test=>smokeIds.has(test.id)),"EvalQA");
    fixture.cases["app-profile-success"]!.observations.profile={kind:"vm",name:"ox.fs.write",args:{path:"MEMORY.md",content:"bad"}};
    expect(()=>validateFixture(fixture)).toThrow();
    const incomplete=fixtureTemplate(cases,"EvalQA");
    expect(()=>validateFixture(incomplete)).toThrow();
  } finally {await rm(directory,{recursive:true,force:true});}
});

test("reports keep simulated evidence distinct and manual review cannot promote missing evidence",async()=>{
  const directory=await mkdtemp(join(tmpdir(),"ox-stub-report-"));
  const report: Report={version:4,startedAt:new Date().toISOString(),revision:"fixture",dirty:false,limits:{timeoutMs:30000,repetitions:1},authorization:{profileWrites:false,installationWrites:false,externalEffects:false,choices:true,qaProfile:"EvalQA"},fixtureHash:"fixture",host:null,provider:"fixture",model:"controlled",catalog:null,mode:"stubbed-ox",plannedCases:["app-profile-success"],results:[{id:"app-profile-success",fixture:"prepared",caseHash:"case",contextHash:"prompt",repetition:1,status:"unverified",checks:[{detail:"independent evidence",passed:true}],rubric:"Review answer",review:{status:"pending"}}]};
  try {
    const input=join(directory,"report.json"),output=join(directory,"reviewed.json");
    await writeFile(input,JSON.stringify(report));
    const reviewed=await command(["--review",input,"--case","app-profile-success","--decision","pass","--note","Reviewed synthetic state and answer","--output",output]);
    expect(reviewed.code,reviewed.stderr).toBe(0);
    const passed=await Bun.file(output).json() as Report;
    expect(compare(passed,{...passed,mode:"ox-cli-conversation"})[0]!.change).toBe("not-comparable");
    expect(compare(report,passed)[0]!.change).toBe("not-comparable");
    report.results[0]!.checks[0]!.passed=false;
    await writeFile(input,JSON.stringify(report));
    expect((await command(["--review",input,"--case","app-profile-success","--decision","pass","--note","Cannot override failure","--output",join(directory,"invalid.json")])).code).toBe(1);
  } finally {await rm(directory,{recursive:true,force:true});}
});
