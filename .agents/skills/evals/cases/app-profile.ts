import { called, mentions, only } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "Which Profile am I using, and where is it stored?",
  checks: run => [called(run, "ox.app.profile"), only(run, ["ox.app.profile", "ox.app.profiles"]), mentions(run, "EvalQA")],
} satisfies EvalCase;
