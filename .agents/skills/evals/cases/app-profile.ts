import { called, mentions, only } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "Which Profile am I using, and where is it stored?",
  stubs: { files: { "app/status.json": JSON.stringify({ profiles: { profiles: [{ name: "EvalQA", storage: "local", active: true }], truncated: false } }) } },
  checks: run => [called(run, "ox.fs.read"), only(run, ["ox.fs.list", "ox.fs.read"]), mentions(run, "EvalQA")],
} satisfies EvalCase;
