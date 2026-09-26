import { describe, expect, test } from "bun:test";
import { cases } from "./cases/index.ts";
import { score } from "./scoring.ts";
import { compare } from "./compare.ts";
import type { EvalResponse, Report } from "./types.ts";

function response(source?: string, text = "ready"): EvalResponse {
  return {
    messages: [{ type: "assistant", assistant: { stopReason: "stop", content: source === undefined
      ? [{ type: "text", text: { text } }]
      : [{ type: "toolCall", toolCall: { name: "execute", arguments: { source } } }] } }],
    systemPrompt: "test", tools: [], totalMs: 1, errors: [],
  };
}

describe("scoring", () => {
  test("does not mistake a function name in a comment or string for a call", () => {
    const fixture = cases.find(test => test.id === "web-tool-decision")!;
    expect(score(fixture, response('console.log("ox.web.search()");')).some(check => !check.passed)).toBe(true);
    expect(score(fixture, response('const result = await ox.web.search({query: "Tokyo weather"}); console.log(result);')).every(check => check.passed)).toBe(true);
  });
  test("rejects malformed JavaScript even when it includes the right calls", () => {
    const fixture = cases.find(test => test.id === "web-tool-decision")!;
    expect(score(fixture, response('ox.web.search(; console.log(result);')).some(check => !check.passed)).toBe(true);
  });
  test("grades the final answer rather than earlier text or tool results", () => {
    const result = response(undefined, "wrong");
    result.messages.unshift(...response().messages);
    expect(score(cases[0]!, result).some(check => !check.passed)).toBe(true);
  });
  test("fixture errors cannot pass on a correct-looking final answer", () => {
    const result = response();
    result.errors.push("Unexpected tool call");
    expect(score(cases[0]!, result).some(check => !check.passed)).toBe(true);
  });
});

const report = (status: "pass" | "fail" | "error", caseHash = "same"): Report => ({
  limits: { timeoutMs: 1000, maxTurns: 6, repetitions: 1 }, version: 1, startedAt: "", revision: "", dirty: false, host: {}, provider: "provider", model: "model", catalog: {},
  mode: "production-agent-fixture-tools",
  results: [{ id: "one", repetition: 1, caseHash, status, checks: [], rubric: "review" }],
});

test("comparison distinguishes regressions from changed cases and infrastructure errors", () => {
  expect(compare(report("pass"), report("fail"))[0]!.change).toBe("regression");
  expect(compare(report("pass"), report("fail", "changed"))[0]!.change).toBe("not-comparable");
  expect(compare(report("pass"), report("error"))[0]!.change).toBe("not-comparable");
});
