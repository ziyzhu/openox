import * as ts from "typescript";
import { isDeepStrictEqual } from "node:util";
import { actions, includes } from "./observations.ts";
import { effectFor } from "./cases/functions.ts";
import type { ActionExpectation, CaseBinding, Check, ConversationEvidence, EvalCase, EvalResponse, EvalSnapshot, Invocation } from "./types.ts";

export function conversationActions(evidence: ConversationEvidence) {
  const before = actions(evidence.initial);
  const after = actions(evidence.snapshot);
  if (!before.every((call, index) => isDeepStrictEqual(call, after[index]))) throw new Error("Initial Action trace changed; cannot attribute model Actions");
  return after.slice(before.length);
}

function matches(call: Invocation, rule: ActionExpectation) {
  return call.name === rule.name && Object.hasOwn(call.outcome, rule.outcome) && (!rule.args || includes(call.args, rule.args));
}

function failureMessages(value: unknown): string[] {
  if (typeof value === "string") return value.trim() ? [value] : [];
  return value && typeof value === "object" ? Object.values(value).flatMap(failureMessages) : [];
}

export function history(snapshot?: EvalSnapshot) {
  const assistants = (snapshot?.messages ?? []).flatMap(message => message.assistant ? [message.assistant] : []);
  const tools = assistants.flatMap(message => message.content.flatMap(block => block.toolCall ? [block.toolCall] : []));
  const results = (snapshot?.messages ?? []).flatMap(message => message.toolResult ? [message.toolResult] : []);
  const last = assistants.at(-1);
  return { assistants, tools, results, last };
}

export function actionChecks(evidence: ConversationEvidence, binding: CaseBinding): Check[] {
  const invocations = conversationActions(evidence);
  return binding.actions.map(rule => {
    const count = invocations.filter(call => matches(call, rule)).length;
    return { detail: `${rule.name} ${rule.outcome}: ${rule.minimum}..${rule.maximum ?? "unbounded"} actual receipts`, passed: count >= rule.minimum && (rule.maximum === undefined || count <= rule.maximum) };
  });
}

export function conversationChecks(evidence: ConversationEvidence, binding: CaseBinding, allowExpectedFailures = true): Check[] {
  const { assistants, tools, results, last } = history(evidence.snapshot);
  const invocations = conversationActions(evidence);
  const failedCalls = invocations.filter(call => "failed" in call.outcome);
  const failedResults = results.filter(result => result.isError);
  const checks: Check[] = [
    { detail: "Every submitted user turn completed", passed: evidence.outcomes.length > 0 && evidence.outcomes.every(turn => turn.outcome === "completed") },
    { detail: "Conversation settled without pending prompts", passed: evidence.snapshot?.isBusy === false && !evidence.snapshot.pendingPrompt },
    { detail: "Complete assistant response", passed: last?.stopReason === "stop" },
    { detail: "No failed, aborted, truncated or pending model response", passed: assistants.every(message => !["error", "aborted", "length", "pending"].includes(message.stopReason)) },
    { detail: "Every tool call has exactly one matching result", passed: tools.every(call => {
      const matching = results.filter(result => result.toolCallId === call.id);
      return matching.length === 1 && matching[0]!.toolName === call.name;
    }) && results.every(result => tools.some(call => call.id === result.toolCallId)) },
    { detail: "Only declared, expected failed Actions occurred", passed: failedCalls.every(call => allowExpectedFailures && binding.actions.some(rule => rule.outcome === "failed" && matches(call, rule))) },
    { detail: "Errored tool results have independently observed expected failures", passed: failedResults.length === 0 || allowExpectedFailures && failedResults.length <= failedCalls.length && failedResults.every(result => result.content.some(block => !!block.text?.text && failedCalls.some(call => failureMessages(call.outcome.failed).some(message => block.text!.text.includes(message))))) },
    { detail: "Only explicitly scoped Actions executed", passed: invocations.every(call => binding.allowedActions.includes(call.name) && !('running' in call.outcome)
      && (effectFor(call.name) === "read" || binding.actions.some(rule => matches(call, rule)))) },
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

export function score(test: EvalCase, binding: CaseBinding, response: EvalResponse): Check[] {
  const checks = [...response.observationChecks,
    { detail: "Evidence captured without transport/provider errors", passed: response.errors.length === 0 },
    ...conversationChecks(response, binding),
    ...actionChecks(response, binding),
  ];
  if (test.skill) {
    const { tools, results } = history(response.snapshot);
    const output = results.filter(result => !result.isError).flatMap(result => result.content.flatMap(block => block.text ? [block.text.text] : [])).join("\n");
    for (const path of [`skills/${test.skill}/SKILL.md`, ...(test.resources ?? [])]) {
      const dedicated = tools.some(call => call.name === "read" && call.arguments.path === path && results.some(result => result.toolCallId === call.id && !result.isError));
      checks.push({ detail: `Required System skill resource actually loaded: ${path}`, passed: dedicated || conversationActions(response).some(call => call.name === "ox.fs.read" && call.args.path === path && "succeeded" in call.outcome) });
      const text = path === response.systemSkill?.path ? response.systemSkill.text : response.systemSkill?.resources[path];
      const prefix = text?.slice(0, 256);
      checks.push({ detail: `Loaded output matches independently observed resource: ${path}`, passed: !!prefix && [prefix, JSON.stringify(prefix).slice(1, -1)].some(value => output.includes(value)) });
    }
  }
  if (test.choice) checks.push({ detail: "Declared workflow choice reached and answered exactly once", passed: response.choices.length === 1 && response.choices[0]?.answer === test.choice.answer });
  if (test.probe) {
    checks.push({ detail: "Fresh-context probe ran independently", passed: !!response.probe && response.probe.chatId !== response.chatId && response.probe.initial?.messages.length === 0 });
    if (response.probe) checks.push(...conversationChecks(response.probe, binding, false).map(check => ({ ...check, detail: `Probe: ${check.detail}` })));
  }
  if (test.effect !== "read") {
    checks.push({ detail: "Run-owned cleanup completed after outcome observation", passed: !!response.cleanup && !!response.restored });
    if (response.cleanup) checks.push(...conversationChecks(response.cleanup, binding, false).map(check => ({ ...check, detail: `Cleanup: ${check.detail}` })));
  }
  return checks;
}
