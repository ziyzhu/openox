import type { ChatSnapshot } from "../../../../apps/cli/src/host-snapshot.ts";

export type Rule =
  | { kind: "answerIncludes" | "answerExcludes" | "answerEquals"; value: string }
  | { kind: "noTools" }
  | { kind: "readsGuidance"; path: string }
  | { kind: "actionAtLeast"; name: string; count: number }
  | { kind: "resultIncludes"; value: string }
  | { kind: "skillWorks" };

export type EvalCase = {
  id: string;
  suite: "quick" | "tasks" | "workflows";
  description: string;
  prompts: string[];
  rules: Rule[];
  rubric: string;
  workflow?:
    | { kind: "guidance"; path: string }
    | { kind: "createSkill"; description: string; instructions: string; probe: string };
};

export type Check = { detail: string; passed: boolean };
export type EvalMessage = {
  type: string;
  assistant?: {
    content: Array<{ type: string; text?: { text: string }; toolCall?: { id: string; name: string; arguments: { source?: string } } }>;
    usage?: unknown;
    stopReason: string;
  };
  toolResult?: { toolCallId: string; toolName: string; isError: boolean; content: Array<{ type: string; text?: { text: string } }> };
};
export type Invocation = {
  name: string;
  args: Record<string, unknown>;
  outcome: { succeeded?: { _0?: unknown }; failed?: unknown; running?: unknown };
};
export type EvalBlock = {
  kind: { type: string; trace?: { entries: Array<{ invocation?: Invocation }>; omittedInvocations?: number } };
};
export type EvalSnapshot = Omit<ChatSnapshot, "messages" | "blocks"> & { messages: EvalMessage[]; blocks: EvalBlock[] };
export type TurnOutcome = { chatId: string; outcome: string; text?: string; error?: string };
export type LogRow = { time: string; level: string; category: string; message: string; [key: string]: unknown };
export type ChatEvidence = {
  chatId: string;
  initial?: EvalSnapshot;
  attention?: EvalSnapshot;
  snapshot?: EvalSnapshot;
  outcomes: TurnOutcome[];
};
export type ObservedState = {
  chatId: string;
  values: Record<string, unknown>;
  files: Record<string, string>;
  guide?: string;
};
export type EvalResponse = ChatEvidence & {
  startedAt: string;
  totalMs: number;
  before?: ObservedState;
  after?: ObservedState;
  restored?: ObservedState;
  fixture?: { name: string; answer: string };
  probe?: { status: "ran"; evidence: ChatEvidence } | { status: "skipped"; reason: string };
  observationChecks: Check[];
  continuation: "safe" | "stop";
  logs: LogRow[];
  logScope: "host-run-window";
  errors: string[];
};

export type CaseResult = {
  id: string;
  caseHash: string;
  repetition: number;
  status: "pass" | "fail" | "error";
  checks: Check[];
  rubric: string;
  contextHash?: string;
  response?: EvalResponse;
  error?: string;
};

export type Report = {
  version: 3;
  startedAt: string;
  revision: string;
  dirty: boolean;
  limits: { timeoutMs: number; repetitions: number };
  authorization: { profileWrites: boolean; qaProfile: string | null };
  host: unknown;
  provider: string;
  model: string;
  catalog: unknown;
  mode: "ox-cli-chat";
  plannedCases: string[];
  results: CaseResult[];
};
