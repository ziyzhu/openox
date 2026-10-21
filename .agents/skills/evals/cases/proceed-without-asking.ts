import { succeeded } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "Make me a packing list for a weekend camping trip and save it as a note.",
  stubs: { functions: { "ox.user.choose": [{ result: "Use your best judgment." }] } },
  checks: async run => {
    const writes = succeeded(run, "ox.fs.write");
    const notes = await Promise.all(writes.map(call => run.read(String(call.args.path))));
    return [
      { detail: "Did not stop to ask with ox.user.choose", passed: succeeded(run, "ox.user.choose").length === 0 },
      { detail: "Saved a note containing a camping packing list", passed: notes.some(text => /tent/i.test(text ?? "") && /sleeping bag/i.test(text ?? "")) },
      { detail: "Reply does not end with a clarifying question", passed: !run.answer.trimEnd().endsWith("?") },
    ];
  },
} satisfies EvalCase;
