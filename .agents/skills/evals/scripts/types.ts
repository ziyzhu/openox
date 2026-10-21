import type { StubFixture } from "../../../../packages/agent/evals/stubs";
import type { AttachedService, Turn } from "../../../../packages/agent/evals/runtime";

export type Check = { detail: string; passed: boolean };
export type Run = Turn & { answer: string; state: Record<string, unknown>; read(path: string): Promise<string | undefined> };
export type EvalCase = {
  task: string;
  stubs?: StubFixture;
  attached?: AttachedService[];
  timeoutMs?: number;
  checks(run: Run): Check[] | Promise<Check[]>;
};
export type Metrics = { elapsedMs: number; modelResponses: number; toolCalls: number; oxCalls: number; failedOxCalls: number; tokens: number; cost: number };
export type Outcome = { status: "pass" | "fail" | "error"; checks: Check[]; answer?: string; metrics?: Metrics; promptHash?: string; error?: string };
export type RunRecord = Outcome & { case: string; variant: string; repetition: number; transcript?: string };
