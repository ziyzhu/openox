import { createHash } from "node:crypto";
import { writeFile } from "node:fs/promises";
import { EvalRuntime, evalModels, type Turn } from "../../../../packages/agent/evals/runtime";
import { loadCase } from "./cases.ts";
import { loadKeys, redact } from "./credentials.ts";
import type { Check, EvalCase, Metrics, Outcome } from "./types.ts";

function metrics(turn: Turn, elapsedMs: number): Metrics {
  const assistants = turn.messages.flatMap(message => message.role === "assistant" ? [message] : []);
  return {
    elapsedMs,
    modelResponses: assistants.length,
    toolCalls: assistants.flatMap(message => message.content.filter(block => block.type === "toolCall")).length,
    oxCalls: turn.calls.length,
    failedOxCalls: turn.calls.filter(call => call.error).length,
    tokens: assistants.reduce((total, message) => total + (message.usage?.totalTokens ?? 0), 0),
    cost: assistants.reduce((total, message) => total + (message.usage?.cost.total ?? 0), 0),
  };
}

function answer(turn: Turn): string {
  const last = turn.messages.flatMap(message => message.role === "assistant" ? [message] : []).at(-1);
  return last?.content.flatMap(block => block.type === "text" ? [block.text] : []).join("\n").trim() ?? "";
}

export async function evaluate(test: EvalCase, provider: string, model: string, timeoutMs: number, models?: Parameters<typeof EvalRuntime.open>[4]): Promise<Outcome & { turn?: Turn }> {
  const started = Date.now();
  let runtime: EvalRuntime | undefined;
  try {
    runtime = await EvalRuntime.open(provider, model, test.stubs, test.attached, models ?? evalModels(provider));
    const turn = await runtime.run(test.task, timeoutMs);
    const base = { answer: answer(turn), metrics: metrics(turn, Date.now() - started), promptHash: createHash("sha256").update(turn.systemPrompt).digest("hex"), turn };
    if (turn.status === "failed") return { ...base, status: "error", checks: [], error: turn.error ?? "Model turn failed" };
    const reader = runtime;
    const checks: Check[] = [
      { detail: `Finished within ${timeoutMs} ms`, passed: turn.status === "completed" },
      ...await test.checks({ ...turn, answer: base.answer, state: runtime.stubs.state, read: async path => (await reader.observe("ox.fs.read", { path }).catch(() => undefined) as { text?: string } | undefined)?.text }),
    ];
    return { ...base, status: checks.every(check => check.passed) ? "pass" : "fail", checks };
  } catch (error) {
    return { status: "error", checks: [], error: String(error) };
  } finally { await runtime?.close(); }
}

if (import.meta.main) {
  const [id, provider, model, timeout, output] = Bun.argv.slice(2);
  if (!id || !provider || !model || !output) throw new Error("Usage: arm.ts <case> <provider> <model> <timeout-ms|default> <output.json>");
  await loadKeys();
  const test = await loadCase(id);
  const timeoutMs = timeout && timeout !== "default" ? Number(timeout) : test.timeoutMs ?? 120_000;
  await writeFile(output, redact(JSON.stringify(await evaluate(test, provider, model, timeoutMs))), { mode: 0o600 });
}
