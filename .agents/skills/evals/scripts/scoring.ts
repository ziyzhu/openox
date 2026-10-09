import * as ts from "typescript";
import { actions, ownedSkillWrite, skillMatches } from "./observations.ts";
import type { ChatEvidence, Check, EvalCase, EvalResponse, EvalSnapshot } from "./types.ts";

function history(snapshot: EvalSnapshot | undefined) {
  const messages = snapshot?.messages ?? [];
  const assistants = messages.flatMap(message => message.assistant ? [message.assistant] : []);
  const tools = assistants.flatMap(message => message.content.flatMap(block => block.toolCall ? [block.toolCall] : []));
  const results = messages.flatMap(message => message.toolResult ? [message.toolResult] : []);
  const last = assistants.at(-1);
  const answer = (last?.content ?? []).filter(block => block.type === "text").map(block => block.text?.text ?? "").join("\n").trim();
  const output = results.filter(result => !result.isError).flatMap(result => result.content.flatMap(block => block.text ? [block.text.text] : [])).join("\n");
  return { assistants, tools, results, last, answer, output };
}

function chatChecks(evidence: ChatEvidence, turns: number): Check[] {
  const { assistants, tools, results, last } = history(evidence.snapshot);
  const checks: Check[] = [
    { detail: "Every user turn completed", passed: evidence.outcomes.length === turns && evidence.outcomes.every(turn => turn.outcome === "completed") },
    { detail: "Chat is idle with no pending approval", passed: evidence.snapshot?.isBusy === false && !evidence.snapshot.pendingPrompt },
    { detail: "Received a complete assistant response", passed: last?.stopReason === "stop" },
    { detail: "No failed, aborted, or truncated model response", passed: assistants.every(message => !["error", "aborted", "length", "pending"].includes(message.stopReason)) },
    { detail: "Every tool call has one successful matching real result", passed: tools.every(call => {
      const matching = results.filter(result => result.toolCallId === call.id);
      return matching.length === 1 && matching[0]!.toolName === call.name && !matching[0]!.isError;
    }) },
  ];
  for (const call of tools) {
    checks.push({ detail: `Declared tool: ${call.name}`, passed: evidence.initial?.tools.some(tool => tool.name === call.name) === true });
    if (call.name !== "execute") continue;
    const source = call.arguments.source ?? "";
    const file = ts.createSourceFile("eval.js", `async function run() {\n${source}\n}`, ts.ScriptTarget.Latest, true, ts.ScriptKind.JS);
    const diagnostics = (file as ts.SourceFile & { parseDiagnostics?: readonly ts.Diagnostic[] }).parseDiagnostics ?? [];
    checks.push({ detail: "Executable JavaScript syntax", passed: source.trim().length > 0 && diagnostics.length === 0 });
  }
  return checks;
}

export function score(test: EvalCase, response: EvalResponse): Check[] {
  const { tools, answer, output } = history(response.snapshot);
  const invocations = actions(response.snapshot);
  const checks: Check[] = [
    ...response.observationChecks,
    { detail: "Evidence captured without CLI or transport errors", passed: response.errors.length === 0 },
    ...chatChecks(response, test.prompts.length),
  ];
  for (const rule of test.rules) {
    switch (rule.kind) {
      case "answerIncludes": checks.push({ detail: `Answer includes ${rule.value}`, passed: answer.toLowerCase().includes(rule.value.toLowerCase()) }); break;
      case "answerExcludes": checks.push({ detail: `Answer excludes ${rule.value}`, passed: !answer.toLowerCase().includes(rule.value.toLowerCase()) }); break;
      case "answerEquals": checks.push({ detail: `Answer equals ${rule.value}`, passed: answer === rule.value }); break;
      case "noTools": checks.push({ detail: "No tools used", passed: tools.length === 0 }); break;
      case "readsSkill": {
        const dedicated = tools.some(call => call.name === "read" && call.arguments.path === rule.path
          && history(response.snapshot).results.some(result => result.toolCallId === call.id && result.toolName === "read" && !result.isError));
        checks.push({ detail: `Actual read of ${rule.path} succeeded`, passed: dedicated || invocations.some(call => call.name === "ox.fs.read" && call.args.path === rule.path && "succeeded" in call.outcome) });
        checks.push({ detail: "Only skill discovery and reads executed", passed: invocations.every(call => ["ox.fs.read", "ox.fs.list", "ox.fs.glob", "ox.fs.grep"].includes(call.name)
          && typeof call.args.path === "string" && (call.args.path === "skills" || call.args.path.startsWith("skills/"))) && tools.every(call => call.name === "execute" || call.name === "read" && call.arguments.path?.startsWith("skills/") === true) });
        const prefix = response.before?.guide?.slice(0, 256);
        checks.push({ detail: "Real tool output contains an independently read skill excerpt", passed: !!prefix && [prefix, JSON.stringify(prefix).slice(1, -1)].some(value => output.includes(value)) });
        break;
      }
      case "actionAtLeast": checks.push({ detail: `${rule.name} actually succeeded at least ${rule.count} times`, passed: invocations.filter(call => call.name === rule.name && "succeeded" in call.outcome).length >= rule.count }); break;
      case "resultIncludes": checks.push({ detail: `Real tool output includes ${rule.value}`, passed: output.toLowerCase().includes(rule.value.toLowerCase()) }); break;
      case "skillWorks": {
        const probe = response.probe?.status === "ran" ? response.probe.evidence : undefined;
        const name = response.fixture?.name ?? "";
        checks.push({ detail: "Task executed an authorized write to the run-owned skill", passed: !!name && invocations.some(call => ownedSkillWrite(call, name) && "succeeded" in call.outcome) });
        checks.push({ detail: "Independently read skill has the requested metadata, instructions, and no extra resources", passed: skillMatches(test, response) });
        if (probe) checks.push(...chatChecks(probe, 1).map(check => ({ ...check, detail: `Probe: ${check.detail}` })));
        checks.push({ detail: "Fresh-chat skill probe returned the run-specific answer", passed: !!probe && !!response.fixture && history(probe.snapshot).answer === response.fixture.answer });
        checks.push({ detail: "Probe actually read the created skill", passed: actions(probe?.snapshot).some(call => call.name === "ox.fs.read" && call.args.path === `skills/${name}/SKILL.md` && "succeeded" in call.outcome) });
        break;
      }
    }
  }
  return checks;
}
