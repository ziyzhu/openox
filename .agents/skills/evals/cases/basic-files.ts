import { called, mentions } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "Read notes.txt from my Profile and tell me the meeting code written there.",
  stubs: { files: { "notes.txt": "The meeting code is MAPLE-739.\n" } },
  checks: run => [called(run, "ox.fs.read"), mentions(run, "MAPLE-739")],
} satisfies EvalCase;
