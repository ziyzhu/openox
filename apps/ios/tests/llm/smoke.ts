import * as ts from "typescript";

type ContentBlock = {
  type?: string;
  text?: string | { text?: string };
  toolCall?: { name?: string; arguments?: unknown };
  name?: string;
  arguments?: unknown;
};

export type SmokeCheck = {
  passed: boolean;
  detail: string;
};

function calleeName(expression: ts.Expression): string | undefined {
  if (ts.isIdentifier(expression)) return expression.text;
  if (ts.isPropertyAccessExpression(expression)) {
    const parent = calleeName(expression.expression);
    return parent ? `${parent}.${expression.name.text}` : undefined;
  }
  return undefined;
}

function callsIn(source: string): { calls: string[]; syntaxErrors: string[] } {
  const file = ts.createSourceFile("protocol-smoke.js", `async function smoke() {\n${source}\n}`, ts.ScriptTarget.Latest, true, ts.ScriptKind.JS);
  const calls: string[] = [];
  const visit = (node: ts.Node): void => {
    if (ts.isCallExpression(node)) {
      const name = calleeName(node.expression);
      if (name) calls.push(name);
    }
    ts.forEachChild(node, visit);
  };
  visit(file);
  const diagnostics = (file as ts.SourceFile & { parseDiagnostics?: readonly ts.Diagnostic[] }).parseDiagnostics ?? [];
  return {
    calls,
    syntaxErrors: diagnostics.map((diagnostic) => ts.flattenDiagnosticMessageText(diagnostic.messageText, " ")),
  };
}

export function scoreSmokeResponse(result: Record<string, unknown>, error?: string): { passed: boolean; checks: SmokeCheck[] } {
  const message = result.message && typeof result.message === "object" ? result.message as Record<string, unknown> : undefined;
  const blocks = Array.isArray(message?.content) ? message.content as ContentBlock[] : [];
  const toolCalls = blocks.flatMap((block) => {
    if (block.type !== "toolCall" && block.type !== "tool_use") return [];
    const call = block.toolCall ?? block;
    return typeof call.name === "string" ? [call] : [];
  });
  const execute = toolCalls.length === 1 && toolCalls[0]?.name === "execute" ? toolCalls[0] : undefined;
  const args = execute?.arguments && typeof execute.arguments === "object" && !Array.isArray(execute.arguments)
    ? execute.arguments as Record<string, unknown>
    : {};
  const source = typeof args.source === "string" ? args.source : "";
  const trace = callsIn(source);
  const webSearchCount = trace.calls.filter((call) => call === "ox.web.search").length;
  const checks: SmokeCheck[] = [
    { passed: error === undefined, detail: `request succeeded${error === undefined ? "" : `: ${error}`}` },
    { passed: execute !== undefined, detail: "uses exactly one execute tool call" },
    { passed: source.trim().length > 0, detail: "JavaScript source is nonempty" },
    { passed: trace.syntaxErrors.length === 0, detail: `JavaScript syntax is valid${trace.syntaxErrors.length > 0 ? `: ${trace.syntaxErrors.join("; ")}` : ""}` },
    { passed: webSearchCount === 1, detail: `invokes ox.web.search once, got ${webSearchCount}` },
    { passed: trace.calls.includes("console.log"), detail: "prints the search result" },
    { passed: !trace.calls.includes("ox.help"), detail: "does not invoke ox.help" },
  ];
  return { passed: checks.every((check) => check.passed), checks };
}
