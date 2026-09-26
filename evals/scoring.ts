import * as ts from "typescript";
import type { Check, EvalCase, EvalResponse } from "./types.ts";

function calleeName(node: ts.Expression): string | undefined {
  if (ts.isIdentifier(node)) return node.text;
  if (ts.isPropertyAccessExpression(node)) {
    const parent = calleeName(node.expression);
    return parent ? `${parent}.${node.name.text}` : undefined;
  }
  return undefined;
}

export function score(test: EvalCase, response: EvalResponse): Check[] {
  const assistants = response.messages.flatMap(message => message.assistant ? [message.assistant] : []);
  const toolCalls = assistants.flatMap(message => message.content.flatMap(block => block.toolCall ? [block.toolCall] : []));
  const last = assistants.at(-1);
  const answer = (last?.content ?? []).filter(block => block.type === "text").map(block => block.text?.text ?? "").join("\n").trim();
  const calls: string[] = [];
  const checks: Check[] = [
    { detail: "Host completed without fixture, budget, or provider errors", passed: response.errors.length === 0 },
    { detail: "Received an assistant response", passed: assistants.length > 0 },
    { detail: "No failed, aborted, or truncated model response", passed: assistants.every(message => !["error", "aborted", "length"].includes(message.stopReason)) },
  ];
  checks.push({ detail: "Expected number of tool calls", passed: toolCalls.length === test.fixtures.length });
  checks.push({ detail: "Final response completed", passed: test.fixtures.at(-1)?.terminate === true || last?.stopReason === "stop" });
  for (const [index, call] of toolCalls.entries()) {
    const callStart = calls.length;
    checks.push({ detail: `Known tool: ${call.name}`, passed: call.name === "execute" });
    const source = call.arguments.source ?? "";
    const file = ts.createSourceFile("eval.js", `async function run() {\n${source}\n}`, ts.ScriptTarget.Latest, true, ts.ScriptKind.JS);
    const diagnostics = (file as ts.SourceFile & { parseDiagnostics?: readonly ts.Diagnostic[] }).parseDiagnostics ?? [];
    checks.push({ detail: "Executable JavaScript syntax", passed: source.trim().length > 0 && diagnostics.length === 0 });
    const visit = (node: ts.Node): void => {
      if (ts.isCallExpression(node)) {
        const name = calleeName(node.expression);
        if (name) calls.push(name);
      }
      ts.forEachChild(node, visit);
    };
    visit(file);
    const required = test.fixtures[index]?.sourceIncludes ?? [];
    checks.push({ detail: "Fixture functions are actual direct calls", passed: required.every(name => calls.slice(callStart).includes(name)) });
  }
  for (const rule of test.rules) {
    switch (rule.kind) {
      case "answerIncludes": checks.push({ detail: `Answer includes ${rule.value}`, passed: answer.toLowerCase().includes(rule.value.toLowerCase()) }); break;
      case "answerExcludes": checks.push({ detail: `Answer excludes ${rule.value}`, passed: !answer.toLowerCase().includes(rule.value.toLowerCase()) }); break;
      case "answerEquals": checks.push({ detail: `Answer equals ${rule.value}`, passed: answer === rule.value }); break;
      case "calls": checks.push({ detail: `${rule.name} called ${rule.count} times`, passed: calls.filter(name => name === rule.name).length === rule.count }); break;
    }
  }
  return checks;
}
