import { called, mentions, only } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "Which model providers do I have set up, and are they signed in?",
  checks: run => [called(run, "ox.provider.list"), only(run, ["ox.provider.list", "ox.provider.get", "ox.provider.models", "ox.app.defaultModel"]), mentions(run, "QA API")],
} satisfies EvalCase;
