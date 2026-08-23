import * as ts from "typescript";

export const evalGroups = ["execute", "no_tool"] as const;

export type EvalGroup = typeof evalGroups[number];

export type EvalTarget = {
  provider: string;
  client: string;
  model: string;
};

export type EvalExpectation = {
  textPatterns?: string[];
  forbiddenTextPatterns?: string[];
  javascriptCalls?: string[];
  javascriptCallCounts?: Record<string, number>;
  javascriptArgumentPatterns?: Record<string, string[]>;
  forbiddenJavascriptCalls?: string[];
  javascriptSourcePatterns?: string[];
  forbiddenJavascriptSourcePatterns?: string[];
};

export type EvalCase = {
  id: string;
  group: EvalGroup;
  prompt: string;
  expect: EvalExpectation;
};

export type EvalCheck = {
  passed: boolean;
  detail: string;
};

export type JavascriptTrace = {
  source: string;
  calls: string[];
  invocations: Array<{ name: string; arguments: string[] }>;
  syntaxErrors: string[];
};

export type EvalScore = {
  passed: boolean;
  text: string;
  toolCalls: Array<{ name: string; arguments: unknown }>;
  javascript?: JavascriptTrace;
  checks: EvalCheck[];
};

type ContentBlock = {
  type?: string;
  text?: string | { text?: string };
  toolCall?: { name?: string; arguments?: unknown };
  name?: string;
  arguments?: unknown;
};

export function parseTarget(value: string): EvalTarget {
  const equals = value.indexOf("=");
  const colon = value.indexOf(":", equals + 1);
  const provider = value.slice(0, equals).trim();
  const client = value.slice(equals + 1, colon).trim();
  const model = value.slice(colon + 1).trim();
  if (equals <= 0 || colon <= equals + 1 || !provider || !client || !model) {
    throw new Error(`Invalid target ${JSON.stringify(value)}; expected provider=client:model`);
  }
  return { provider, client, model };
}

export function validateProviderCoverage(targets: EvalTarget[], allowSingleProvider: boolean): void {
  if (targets.length === 0) throw new Error("Pass at least one --target provider=client:model");
  const providers = new Set(targets.map((target) => target.provider.toLowerCase()));
  if (!allowSingleProvider && providers.size < 2) {
    throw new Error("Real-model acceptance requires at least two provider families; pass --allow-single-provider only for focused diagnostics");
  }
  const identities = targets.map((target) => `${target.client}:${target.model}`);
  if (new Set(identities).size !== identities.length) throw new Error("Duplicate client:model target");
}

function strings(value: unknown, label: string): string[] | undefined {
  if (value === undefined) return undefined;
  if (!Array.isArray(value) || value.some((entry) => typeof entry !== "string")) throw new Error(`${label} must be an array of strings`);
  return value;
}

function countMap(value: unknown, label: string): Record<string, number> | undefined {
  if (value === undefined) return undefined;
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${label} must be an object of counts`);
  for (const [key, count] of Object.entries(value)) {
    if (!Number.isInteger(count) || Number(count) < 0) throw new Error(`${label}.${key} must be a non-negative integer`);
  }
  return value as Record<string, number>;
}

function patternListMap(value: unknown, label: string): Record<string, string[]> | undefined {
  if (value === undefined) return undefined;
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${label} must be an object of pattern arrays`);
  for (const [key, patterns] of Object.entries(value)) strings(patterns, `${label}.${key}`);
  return value as Record<string, string[]>;
}

function validateExpectation(group: EvalGroup, value: unknown, id: string): EvalExpectation {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`Case ${id} needs expectations`);
  const raw = value as Record<string, unknown>;
  const expectation: EvalExpectation = {
    textPatterns: strings(raw.textPatterns, `Case ${id} textPatterns`),
    forbiddenTextPatterns: strings(raw.forbiddenTextPatterns, `Case ${id} forbiddenTextPatterns`),
    javascriptCalls: strings(raw.javascriptCalls, `Case ${id} javascriptCalls`),
    javascriptCallCounts: countMap(raw.javascriptCallCounts, `Case ${id} javascriptCallCounts`),
    javascriptArgumentPatterns: patternListMap(raw.javascriptArgumentPatterns, `Case ${id} javascriptArgumentPatterns`),
    forbiddenJavascriptCalls: strings(raw.forbiddenJavascriptCalls, `Case ${id} forbiddenJavascriptCalls`),
    javascriptSourcePatterns: strings(raw.javascriptSourcePatterns, `Case ${id} javascriptSourcePatterns`),
    forbiddenJavascriptSourcePatterns: strings(raw.forbiddenJavascriptSourcePatterns, `Case ${id} forbiddenJavascriptSourcePatterns`),
  };
  const patterns = [
    ...(expectation.textPatterns ?? []),
    ...(expectation.forbiddenTextPatterns ?? []),
    ...Object.values(expectation.javascriptArgumentPatterns ?? {}).flat(),
    ...(expectation.javascriptSourcePatterns ?? []),
    ...(expectation.forbiddenJavascriptSourcePatterns ?? []),
  ];
  for (const pattern of patterns) {
    try { new RegExp(pattern, "iu"); } catch { throw new Error(`Case ${id} has invalid pattern ${JSON.stringify(pattern)}`); }
  }
  const javascriptKeys = [expectation.javascriptCalls, expectation.javascriptCallCounts, expectation.javascriptArgumentPatterns, expectation.forbiddenJavascriptCalls, expectation.javascriptSourcePatterns, expectation.forbiddenJavascriptSourcePatterns];
  if (group !== "execute" && javascriptKeys.some((entry) => entry !== undefined)) {
    throw new Error(`Case ${id} has JavaScript expectations outside execute`);
  }
  return Object.fromEntries(Object.entries(expectation).filter(([, entry]) => entry !== undefined)) as EvalExpectation;
}

export function validateCases(value: unknown): EvalCase[] {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Eval corpus must be an object grouped by tool");
  const corpus = value as Record<string, unknown>;
  const unknownGroups = Object.keys(corpus).filter((group) => !evalGroups.includes(group as EvalGroup));
  if (unknownGroups.length > 0) throw new Error(`Unknown eval groups: ${unknownGroups.join(", ")}`);
  const ids = new Set<string>();
  const cases: EvalCase[] = [];
  for (const group of evalGroups) {
    const entries = corpus[group];
    if (!Array.isArray(entries)) throw new Error(`Eval group ${group} must be an array`);
    for (const [index, entry] of entries.entries()) {
      if (!entry || typeof entry !== "object" || Array.isArray(entry)) throw new Error(`${group} case ${index + 1} must be an object`);
      const item = entry as Record<string, unknown>;
      if (typeof item.id !== "string" || !item.id.trim()) throw new Error(`${group} case ${index + 1} needs an id`);
      if (ids.has(item.id)) throw new Error(`Duplicate case id ${item.id}`);
      ids.add(item.id);
      if (typeof item.prompt !== "string" || !item.prompt.trim()) throw new Error(`Case ${item.id} needs a prompt`);
      cases.push({ id: item.id, group, prompt: item.prompt, expect: validateExpectation(group, item.expect, item.id) });
    }
  }
  if (cases.length === 0) throw new Error("Eval corpus must contain at least one case");
  return cases;
}

function extractText(blocks: ContentBlock[]): string {
  return blocks.flatMap((block) => {
    if (block.type !== "text") return [];
    if (typeof block.text === "string") return [block.text];
    return block.text?.text ? [block.text.text] : [];
  }).join("\n").trim();
}

function extractToolCalls(blocks: ContentBlock[]): Array<{ name: string; arguments: unknown }> {
  return blocks.flatMap((block) => {
    if (block.type !== "toolCall" && block.type !== "tool_use") return [];
    const value = block.toolCall ?? block;
    return typeof value.name === "string" ? [{ name: value.name, arguments: value.arguments }] : [];
  });
}

function calleeName(expression: ts.Expression): string | undefined {
  if (ts.isIdentifier(expression)) return expression.text;
  if (ts.isPropertyAccessExpression(expression)) {
    const parent = calleeName(expression.expression);
    return parent ? `${parent}.${expression.name.text}` : undefined;
  }
  return undefined;
}

export function traceJavascript(source: string): JavascriptTrace {
  const file = ts.createSourceFile("eval.js", `async function __oxEval() {\n${source}\n}`, ts.ScriptTarget.Latest, true, ts.ScriptKind.JS);
  const calls: string[] = [];
  const invocations: Array<{ name: string; arguments: string[] }> = [];
  const visit = (node: ts.Node): void => {
    if (ts.isCallExpression(node)) {
      const name = calleeName(node.expression);
      if (name) {
        calls.push(name);
        invocations.push({ name, arguments: node.arguments.map((argument) => argument.getText(file)) });
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(file);
  const diagnostics = (file as ts.SourceFile & { parseDiagnostics?: readonly ts.Diagnostic[] }).parseDiagnostics ?? [];
  const syntaxErrors = diagnostics.map((diagnostic) => ts.flattenDiagnosticMessageText(diagnostic.messageText, " "));
  return { source, calls, invocations, syntaxErrors };
}

function patternCheck(value: string, pattern: string, expected: boolean): EvalCheck {
  const matched = new RegExp(pattern, "iu").test(value);
  return { passed: matched === expected, detail: `${expected ? "matches" : "does not match"} /${pattern}/iu` };
}

function toolArguments(call: { arguments: unknown } | undefined): Record<string, unknown> {
  return call?.arguments && typeof call.arguments === "object" && !Array.isArray(call.arguments) ? call.arguments as Record<string, unknown> : {};
}

export function scoreResponse(testCase: EvalCase, result: Record<string, unknown>): EvalScore {
  const message = result.message && typeof result.message === "object" ? result.message as Record<string, unknown> : undefined;
  const blocks = Array.isArray(message?.content) ? message.content as ContentBlock[] : [];
  const text = extractText(blocks);
  const toolCalls = extractToolCalls(blocks);
  const expectedTool = testCase.group === "no_tool" ? undefined : testCase.group;
  const selectedTool = expectedTool ? toolCalls.find((call) => call.name === expectedTool) : undefined;
  const argumentsValue = toolArguments(selectedTool);
  const source = typeof argumentsValue.source === "string" ? argumentsValue.source : "";
  const javascript = testCase.group === "execute" ? traceJavascript(source) : undefined;
  const checks: EvalCheck[] = [];

  if (result.ok !== true) checks.push({ passed: false, detail: `request succeeded: ${String(result.error ?? "unknown error")}` });
  checks.push(expectedTool
    ? { passed: toolCalls.length === 1 && toolCalls[0]?.name === expectedTool, detail: `uses exactly one ${expectedTool} tool call` }
    : { passed: toolCalls.length === 0, detail: "uses no tools" });
  for (const pattern of testCase.expect.textPatterns ?? []) checks.push(patternCheck(text, pattern, true));
  for (const pattern of testCase.expect.forbiddenTextPatterns ?? []) checks.push(patternCheck(text, pattern, false));
  if (javascript) {
    checks.push({ passed: source.trim().length > 0, detail: "JavaScript source is nonempty" });
    checks.push({ passed: javascript.syntaxErrors.length === 0, detail: `JavaScript syntax is valid${javascript.syntaxErrors.length > 0 ? `: ${javascript.syntaxErrors.join("; ")}` : ""}` });
    for (const call of testCase.expect.javascriptCalls ?? []) {
      checks.push({ passed: javascript.calls.includes(call), detail: `JavaScript invokes ${call}` });
    }
    for (const [call, count] of Object.entries(testCase.expect.javascriptCallCounts ?? {})) {
      const actual = javascript.calls.filter((candidate) => candidate === call).length;
      checks.push({ passed: actual === count, detail: `JavaScript invokes ${call} ${count} time(s), got ${actual}` });
    }
    for (const [call, patterns] of Object.entries(testCase.expect.javascriptArgumentPatterns ?? {})) {
      const argumentsText = javascript.invocations.filter((invocation) => invocation.name === call).flatMap((invocation) => invocation.arguments).join("\n");
      for (const pattern of patterns) checks.push(patternCheck(argumentsText, pattern, true));
    }
    for (const call of testCase.expect.forbiddenJavascriptCalls ?? []) {
      checks.push({ passed: !javascript.calls.includes(call), detail: `JavaScript does not invoke ${call}` });
    }
    for (const pattern of testCase.expect.javascriptSourcePatterns ?? []) checks.push(patternCheck(source, pattern, true));
    for (const pattern of testCase.expect.forbiddenJavascriptSourcePatterns ?? []) checks.push(patternCheck(source, pattern, false));
  }

  return { passed: checks.every((check) => check.passed), text, toolCalls, javascript, checks };
}

export function passesThreshold(outcomes: Array<{ passed: boolean }>, minimum: number): boolean {
  if (outcomes.length === 0) return false;
  return outcomes.filter((outcome) => outcome.passed).length / outcomes.length >= minimum;
}
