import type { StubFixture } from "../../../../packages/agent/evals/stubs";
import type { ConversationSnapshot } from "../../../../apps/cli/src/host-snapshot.ts";

export type Variant = "success" | "failure" | "boundary";
export type Effect = "read" | "profile" | "installation" | "external";
export type Choice = { options: string[]; answer: string };
export type EvalCase = {
  id: string;
  suite: "functions" | "workflows" | "safety";
  description: string;
  function?: string;
  functions?: string[];
  skill?: string;
  resources?: string[];
  variant: Variant;
  effect: Effect;
  task: string;
  evidence: Record<string, string>;
  choice?: Choice;
  followups?: string[];
  probe?: string;
  rubric: string;
};
export type Reader = (
  | { kind: "vm"; name: string; args: Record<string, unknown> }
  | { kind: "skill"; name: string }
  | { kind: "conversation"; id: string | { $receipt: string; path: string[] } }
  | { kind: "cli"; command: "providers" | "conversations" }
) & { phases?: Array<"before" | "after" | "cleanup"> };
export type Assertion = {
  evidence: string;
  phase: "before" | "after" | "probe" | "cleanup";
  observation: string;
  path: string[];
  operator: "equals" | "includes" | "unchanged" | "absent";
  expected?: unknown;
};
export type ActionExpectation = {
  name: string;
  outcome: "succeeded" | "failed";
  minimum: number;
  maximum?: number;
  args?: Record<string, unknown>;
};
export type CaseBinding = {
  stubs?: StubFixture;
  context: string;
  probeContext?: string;
  observations: Record<string, Reader>;
  assertions: Assertion[];
  actions: ActionExpectation[];
  allowedActions: string[];
  cleanup?: string;
};
export type Check = { detail: string; passed: boolean };
export type Fixture = { version: 1; qaProfile: string; cases: Record<string, CaseBinding> };
export type EvalMessage = {
  type: string;
  assistant?: {
    content: Array<{ type: string; text?: { text: string }; toolCall?: { id: string; name: string; arguments: { source?: string; path?: string } } }>;
    usage?: unknown;
    stopReason: string;
  };
  toolResult?: { toolCallId: string; toolName: string; isError: boolean; content: Array<{ type: string; text?: { text: string } }> };
};
export type Invocation = {
  name: string;
  args: Record<string, unknown>;
  outcome: { succeeded?: { _0?: unknown }; failed?: unknown; running?: unknown };
  preview?: { argumentsTruncated: boolean; resultTruncated: boolean; purposeTruncated: boolean };
};
export type EvalBlock = { kind: { type: string; trace?: { entries: Array<{ invocation?: Invocation }>; omittedInvocations?: number } } };
export type EvalSnapshot = Omit<ConversationSnapshot, "messages" | "blocks"> & { messages: EvalMessage[]; blocks: EvalBlock[] };
export type TurnOutcome = { chatId: string; outcome: string; text?: string; error?: string };
export type ConversationEvidence = {
  chatId: string;
  initial?: EvalSnapshot;
  attention?: EvalSnapshot;
  snapshot?: EvalSnapshot;
  outcomes: TurnOutcome[];
  choices: Array<{ prompt: NonNullable<EvalSnapshot["pendingPrompt"]>; answer: string }>;
};
export type ObservedState = { values: Record<string, unknown> };
export type LogRow = { time: string; level: string; category: string; message: string; [key: string]: unknown };
export type EvalResponse = ConversationEvidence & {
  startedAt: string;
  totalMs: number;
  before?: ObservedState;
  after?: ObservedState;
  systemSkill?: { path: string; text: string; resources: Record<string, string> };
  restored?: ObservedState;
  probe?: ConversationEvidence;
  cleanup?: ConversationEvidence;
  observationChecks: Check[];
  continuation: "safe" | "stop";
  blocked?: string;
  logs: LogRow[];
  logScope: "host-run-window" | "stub-run";
  errors: string[];
};
export type CaseResult = {
  id: string;
  fixture: "prepared" | "missing";
  caseHash: string;
  repetition: number;
  status: "pass" | "fail" | "error" | "blocked" | "unverified";
  checks: Check[];
  rubric: string;
  review: { status: "pending" | "pass" | "fail"; note?: string };
  contextHash?: string;
  response?: EvalResponse;
  error?: string;
};
export type Report = {
  version: 4;
  startedAt: string;
  revision: string;
  dirty: boolean;
  limits: { timeoutMs: number; repetitions: number };
  authorization: { profileWrites: boolean; installationWrites: boolean; externalEffects: boolean; choices: boolean; qaProfile: string };
  fixtureHash: string;
  host: unknown;
  provider: string;
  model: string;
  catalog: unknown;
  mode: "ox-cli-chat" | "stubbed-ox";
  plannedCases: string[];
  results: CaseResult[];
};
