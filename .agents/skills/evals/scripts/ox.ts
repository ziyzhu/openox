import { randomUUID } from "node:crypto";
import { newChat, ox, vmCall } from "./cli.ts";
import { observeState, permittedActions, preserved, render, requireCleanupPolicy } from "./observations.ts";
import type { ChatEvidence, EvalCase, EvalResponse, EvalSnapshot, LogRow, TurnOutcome } from "./types.ts";

async function runChat(host: string, provider: string, model: string, prompts: string[], temporary: boolean, evidence: ChatEvidence, remaining: () => number, errors: string[]): Promise<void> {
  try {
    evidence.chatId = await newChat(host, provider, model, temporary, remaining());
    evidence.initial = await ox<EvalSnapshot>(host, ["chat", "inspect", "--full"], evidence.chatId, remaining());
    if (evidence.initial.id !== evidence.chatId || evidence.initial.messages.length || evidence.initial.isBusy !== false || evidence.initial.pendingPrompt) throw new Error("New chat is not empty and idle");
    for (const prompt of prompts) {
      const outcome = await ox<TurnOutcome>(host, ["chat", "send", prompt], evidence.chatId, remaining(), true);
      if (outcome.chatId !== evidence.chatId || !["completed", "needsAttention", "failed", "cancelled"].includes(outcome.outcome)) throw new Error("Unexpected chat send result");
      evidence.outcomes.push(outcome);
      if (["failed", "cancelled"].includes(outcome.outcome)) errors.push(outcome.error ?? `Chat ${outcome.outcome}`);
      if (outcome.outcome !== "completed") break;
    }
  } catch (error) { errors.push(String(error)); }
  if (!evidence.chatId) return;
  if (evidence.outcomes.at(-1)?.outcome === "needsAttention") {
    try { evidence.attention = await ox<EvalSnapshot>(host, ["chat", "inspect", "--full"], evidence.chatId); }
    catch (error) { errors.push(`Pending prompt capture failed: ${String(error)}`); }
  }
  if (errors.length || evidence.outcomes.at(-1)?.outcome !== "completed") {
    try { await ox(host, ["chat", "stop"], evidence.chatId); }
    catch (error) { errors.push(`Stop failed: ${String(error)}`); }
  }
  try {
    evidence.snapshot = await ox<EvalSnapshot>(host, ["chat", "inspect", "--full"], evidence.chatId);
    if (evidence.snapshot.id !== evidence.chatId || evidence.snapshot.isBusy !== false || evidence.snapshot.pendingPrompt) errors.push("Chat did not settle; do not start another attempt");
    if (evidence.snapshot.blocks.some(block => (block.kind.trace?.omittedInvocations ?? 0) > 0)) errors.push("Action receipts are incomplete; behavior is unverified");
  } catch (error) { errors.push(`Snapshot failed: ${String(error)}`); }
}

export async function runCase(host: string, provider: string, model: string, test: EvalCase, timeoutMs: number, qaProfile?: string): Promise<EvalResponse> {
  const started = Date.now();
  const response: EvalResponse = {
    chatId: "", startedAt: new Date(started).toISOString(), totalMs: 0, outcomes: [],
    observationChecks: [], continuation: "stop", logs: [], logScope: "host-run-window", errors: [],
  };
  const remaining = () => {
    const budget = timeoutMs - (Date.now() - started);
    if (budget <= 0) throw new Error("Case deadline exceeded");
    return budget;
  };
  try {
    if (test.workflow) response.before = await observeState(host, provider, model, test, remaining, qaProfile);
    if (test.workflow?.kind === "createSkill") {
      if (!qaProfile || !response.before) throw new Error("Skill workflow requires a named local QA Profile");
      await requireCleanupPolicy(host, response.before, remaining);
      const id = randomUUID().replaceAll("-", "");
      response.fixture = { name: `ox-eval-${id}`, answer: `OX_EVAL_OK_${randomUUID().replaceAll("-", "")}` };
      if (Object.keys(response.before.files).some(path => path.startsWith(`skills/${response.fixture!.name}/`))) throw new Error("Fixture name already exists; leave it untouched");
    }
    await runChat(host, provider, model, test.prompts.map(prompt => render(prompt, response.fixture)), test.workflow?.kind !== "createSkill", response, remaining, response.errors);
    if (test.workflow && response.snapshot?.isBusy === false) {
      response.after = await observeState(host, provider, model, test, remaining, qaProfile);
      response.observationChecks.push(...preserved(response.before!, response.after, response.fixture), ...permittedActions(response, response.fixture));
    }
    if (test.workflow?.kind === "createSkill" && response.after && response.errors.length === 0 && response.outcomes.every(outcome => outcome.outcome === "completed")
      && response.observationChecks.every(check => check.passed)) {
      if (response.after.files[`skills/${response.fixture!.name}/SKILL.md`] !== undefined) {
        const evidence: ChatEvidence = { chatId: "", outcomes: [] };
        response.probe = { status: "ran", evidence };
        await runChat(host, provider, model, [render(test.workflow.probe, response.fixture)], true, evidence, remaining, response.errors);
      } else response.probe = { status: "skipped", reason: "Created skill is absent from independent state" };
    }
  } catch (error) { response.errors.push(`Observation/workflow failed: ${String(error)}`); }
  if (response.probe?.status === "ran") response.observationChecks.push(...permittedActions(response.probe.evidence).map(check => ({ ...check, detail: `Probe: ${check.detail}` })));
  if (test.workflow?.kind === "createSkill" && !response.probe) response.probe = { status: "skipped", reason: "Task did not complete, evidence is missing, or monitored invariants failed" };
  const settled = (!response.chatId || response.snapshot?.isBusy === false && !response.snapshot.pendingPrompt)
    && (response.probe?.status !== "ran" || response.probe.evidence.snapshot?.isBusy === false && !response.probe.evidence.snapshot.pendingPrompt);
  if (test.workflow?.kind === "createSkill" && response.fixture && response.chatId && settled) {
    const deadline = Date.now() + 30_000;
    const recover = () => {
      const budget = deadline - Date.now();
      if (budget <= 0) throw new Error("Cleanup/evidence deadline exceeded");
      return budget;
    };
    try {
      if (!response.after) {
        response.after = await observeState(host, provider, model, test, recover, qaProfile);
        response.observationChecks.push(...preserved(response.before!, response.after, response.fixture), ...permittedActions(response, response.fixture));
      }
      if (Object.keys(response.after.files).some(path => path.startsWith(`skills/${response.fixture!.name}/`))) {
        await ox(host, ["chat", "open"], response.chatId, recover());
        const profile = await vmCall(host, response.chatId, "ox.app.profile", {}, recover());
        if (JSON.stringify(profile) !== JSON.stringify(response.before!.values.profile)) throw new Error("QA Profile changed; leave cleanup to the owner");
        const policy = await vmCall<{ resolved: { policy: string } }>(host, response.chatId, "ox.app.actionPolicies", { action: "ox.skill.delete" }, recover());
        if (policy.resolved?.policy !== "allow") throw new Error("Cleanup no longer allowed; no approval was submitted");
        const deleted = await vmCall<{ name: string; deleted: boolean }>(host, response.chatId, "ox.skill.delete", { name: response.fixture.name, purpose: "Remove eval fixture" }, recover());
        if (deleted.name !== response.fixture.name || deleted.deleted !== true) throw new Error("Fixture deletion did not complete");
      }
      response.restored = await observeState(host, provider, model, test, recover, qaProfile);
      response.observationChecks.push(...preserved(response.before!, response.restored), {
        detail: "Only the run-owned skill was removed during cleanup",
        passed: !Object.keys(response.restored.files).some(path => path.startsWith(`skills/${response.fixture!.name}/`)),
      });
    } catch (error) { response.errors.push(`Cleanup failed: ${String(error)}`); }
  }
  if (test.workflow?.kind === "readSkill") {
    response.observationChecks.push({ detail: "Independent skill contents unchanged", passed: !!response.before?.guide && response.before.guide === response.after?.guide });
  }
  if (settled && response.errors.length === 0 && response.observationChecks.every(check => check.passed)) response.continuation = "safe";
  try {
    response.logs = await ox<LogRow[]>(host, ["host", "logs", "--since", response.startedAt, "--all"]);
    if (!Array.isArray(response.logs)) throw new Error("Expected a log array");
  } catch (error) { response.errors.push(`Logs failed: ${String(error)}`); response.continuation = "stop"; }
  response.totalMs = Date.now() - started;
  return response;
}
