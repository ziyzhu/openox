import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "What is 17 plus 25? Reply with only the number, without using tools.",
  checks: run => [
    { detail: "Follows a basic instruction and answers correctly", passed: run.answer.trim() === "42" },
    { detail: "Does not invoke an Ox function for simple arithmetic", passed: run.calls.length === 0 },
  ],
} satisfies EvalCase;
