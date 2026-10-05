export type Fixture = {
  tool: string;
  sourceIncludes: string[];
  text: string;
  isError: boolean;
  terminate: boolean;
};

export type Rule =
  | { kind: "answerIncludes" | "answerExcludes"; value: string }
  | { kind: "answerEquals"; value: string }
  | { kind: "calls"; name: string; count: number };

export type EvalCase = {
  id: string;
  suite: "quick" | "tasks";
  description: string;
  prompts: string[];
  fixtures: Fixture[];
  rules: Rule[];
  rubric: string;
};

export type Check = { detail: string; passed: boolean };
export type EvalResponse = {
  messages: Array<{
    type: string;
    assistant?: {
      content: Array<{ type: string; text?: { text: string }; toolCall?: { name: string; arguments: { source?: string } } }>;
      usage?: { input: number; output: number };
      stopReason: string;
    };
  }>;
  systemPrompt: string;
  tools: unknown[];
  temperature?: number;
  maxTokens?: number;
  totalMs: number;
  errors: string[];
  executionError?: string;
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
  version: 1;
  startedAt: string;
  revision: string;
  dirty: boolean;
  limits: { timeoutMs: number; maxTurns: number; repetitions: number };
  host: unknown;
  provider: string;
  model: string;
  catalog: unknown;
  mode: "production-agent-fixture-tools";
  results: CaseResult[];
};
