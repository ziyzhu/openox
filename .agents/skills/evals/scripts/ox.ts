import { newConversation, ox, vmCall } from "./cli.ts";
import { assertions, observeState, readers } from "./observations.ts";
import { actionChecks, conversationChecks } from "./scoring.ts";
import type { CaseBinding, Choice, ConversationEvidence, EvalCase, EvalResponse, EvalSnapshot, LogRow, TurnOutcome } from "./types.ts";

export type RunOptions = { qaProfile: string; choices: boolean; humanWaitMs: number };
const evidence = (chatId = ""): ConversationEvidence => ({ chatId, outcomes: [], choices: [] });

async function readSystemSkill(host: string, chatId: string, path: string, remaining: () => number): Promise<string> {
  const file = await vmCall<{ path: string; text: string; truncated: boolean; unsupported: string | null }>(host, chatId, "ox.fs.read", { path, options: { maxBytes: 1_048_576 } }, remaining());
  if (file?.path !== path || typeof file.text !== "string" || !file.text.trim() || file.truncated !== false || file.unsupported) throw new Error("System skill observation is missing or incomplete");
  return file.text;
}

async function inspect(host: string, chatId: string, remaining: () => number): Promise<EvalSnapshot> {
  const snapshot = await ox<EvalSnapshot>(host, ["conversation", "inspect", "--full"], chatId, remaining());
  if (snapshot.id !== chatId || snapshot.blocks.some(block => (block.kind.trace?.omittedInvocations ?? 0) > 0)) throw new Error("Wrong conversation or incomplete Action receipts");
  return snapshot;
}

async function awaitTurn(host: string, target: ConversationEvidence, options: RunOptions, remaining: () => number, choice?: Choice): Promise<boolean> {
  const snapshot = await inspect(host, target.chatId, remaining);
  target.attention = snapshot;
  const prompt = snapshot.pendingPrompt;
  if (!prompt) throw new Error("needsAttention without an observable pending prompt");
  if (choice && options.choices && target.choices.length === 0 && !prompt.requiresApp
    && JSON.stringify(prompt.options) === JSON.stringify(choice.options)) {
    await ox(host, ["conversation", "respond", choice.answer, "--prompt", prompt.id], target.chatId, remaining());
    target.choices.push({ prompt, answer: choice.answer });
  } else if (!options.humanWaitMs) return false;
  else console.log(`HUMAN ${target.chatId}: ${prompt.prompt} (complete in QA Ox; runner never approves native gates)`);
  const deadline = Date.now() + (options.humanWaitMs || Math.min(remaining(), 30_000));
  let lastPrompt = prompt.id;
  while (Date.now() < deadline) {
    const current = await inspect(host, target.chatId, remaining);
    if (!current.isBusy && !current.pendingPrompt) {
      target.snapshot = current;
      return true;
    }
    if (current.pendingPrompt && current.pendingPrompt.id !== lastPrompt) {
      if (!options.humanWaitMs) { target.attention = current; return false; }
      lastPrompt = current.pendingPrompt.id;
      console.log(`HUMAN ${target.chatId}: ${current.pendingPrompt.prompt}`);
    }
    await Bun.sleep(Math.min(250, remaining()));
  }
  return false;
}

async function runConversation(host: string, provider: string, model: string, prompts: string[], temporary: boolean,
  target: ConversationEvidence, response: EvalResponse, options: RunOptions, remaining: () => number, choice?: Choice): Promise<void> {
  try {
    if (!target.chatId) target.chatId = await newConversation(host, provider, model, temporary, remaining());
    target.initial = await inspect(host, target.chatId, remaining);
    if (target.initial.messages.length || target.initial.isBusy !== false || target.initial.pendingPrompt) throw new Error("Expected a fresh empty and idle QA conversation");
    for (const text of prompts) {
      const outcome = await ox<TurnOutcome>(host, ["conversation", "send", text], target.chatId, remaining(), true);
      if (outcome.chatId !== target.chatId || !["completed", "needsAttention", "failed", "cancelled"].includes(outcome.outcome)) throw new Error("Unexpected conversation outcome; input may have been submitted, never resubmitting");
      target.outcomes.push(outcome);
      if (outcome.outcome === "needsAttention") {
        if (!await awaitTurn(host, target, options, remaining, choice)) {
          response.blocked = `Unanswered or unsupported checkpoint in ${target.chatId}`;
          break;
        }
        outcome.outcome = "completed";
      } else if (outcome.outcome !== "completed") {
        response.errors.push(outcome.error ?? `Conversation ${outcome.outcome}`);
        break;
      }
    }
  } catch (error) { response.errors.push(String(error)); }
  if (!target.chatId) return;
  if (response.errors.length || target.outcomes.at(-1)?.outcome !== "completed") {
    try { await ox(host, ["conversation", "stop"], target.chatId, 10_000); }
    catch (error) { response.errors.push(`Stop failed: ${String(error)}`); }
  }
  try {
    target.snapshot = await inspect(host, target.chatId, () => 10_000);
    if (target.snapshot.isBusy !== false || target.snapshot.pendingPrompt) response.errors.push("Conversation did not settle; no further task or cleanup is safe");
  } catch (error) { response.errors.push(`Snapshot failed: ${String(error)}`); }
}

export async function runCase(host: string, provider: string, model: string, test: EvalCase, binding: CaseBinding, timeoutMs: number, options: RunOptions): Promise<EvalResponse> {
  const started = Date.now();
  const response: EvalResponse = { ...evidence(), startedAt: new Date(started).toISOString(), totalMs: 0,
    observationChecks: [], continuation: "stop", logs: [], logScope: "host-run-window", errors: [] };
  const remaining = () => {
    const budget = timeoutMs - (Date.now() - started);
    if (budget <= 0) throw new Error("Case deadline exceeded");
    return budget;
  };
  try {
    response.chatId = await newConversation(host, provider, model, test.effect === "read", remaining());
    const profile = await vmCall<{ name: string; storage: string }>(host, response.chatId, "ox.app.profile", {}, remaining());
    if (profile?.name !== options.qaProfile || profile.storage !== "local") throw new Error("Expected the named local QA Profile; no task submitted");
    if (test.skill) {
      const path = `skills/${test.skill}/SKILL.md`;
      response.systemSkill = { path, text: await readSystemSkill(host, response.chatId, path, remaining), resources: {} };
      for (const resource of test.resources ?? []) response.systemSkill.resources[resource] = await readSystemSkill(host, response.chatId, resource, remaining);
    }
    response.before = await observeState(host, response.chatId, binding, remaining, "before");
    const preconditions = assertions(binding, response, "before");
    response.observationChecks.push(...preconditions);
    if (preconditions.some(check => !check.passed)) {
      response.blocked = "QA preconditions do not hold; no task submitted";
      return response;
    }
    const prompt = test.task.replaceAll("{{context}}", binding.context);
    await runConversation(host, provider, model, [prompt, ...(test.followups ?? []).map(text => text.replaceAll("{{context}}", binding.context))], test.effect === "read", response, response, options, remaining, test.choice);
    if (response.errors.length || response.blocked) return response;
    response.after = await observeState(host, response.chatId, binding, remaining, "after");
    response.observationChecks.push(...assertions(binding, response, "after"));
    if (response.systemSkill) {
      for (const [path, text] of Object.entries({ [response.systemSkill.path]: response.systemSkill.text, ...response.systemSkill.resources })) {
        response.observationChecks.push({ detail: `System skill resource independently observed and preserved: ${path}`, passed: text === await readSystemSkill(host, response.chatId, path, remaining) });
      }
    }
    const taskChecks = [...conversationChecks(response, binding), ...actionChecks(response, binding)];
    const preserved = response.observationChecks.filter(check => check.detail.startsWith("after: preserved "));
    if (!preserved.length || preserved.some(check => !check.passed) || taskChecks.some(check => !check.passed)) return response;
    if (test.probe) {
      response.probe = evidence();
      await runConversation(host, provider, model, [test.probe.replaceAll("{{probeContext}}", binding.probeContext!)], true, response.probe, response, options, remaining);
      response.observationChecks.push(...assertions(binding, response, "probe"));
      const probeScope = { ...binding, allowedActions: binding.allowedActions.filter(name => readers.has(name) || name === "ox.tool.help") };
      if (response.errors.length || response.blocked || conversationChecks(response.probe, probeScope, false).some(check => !check.passed)) return response;
      response.after = await observeState(host, response.chatId, binding, remaining, "after");
      response.observationChecks.push(...assertions(binding, response, "after").map(check => ({ ...check, detail: `After probe: ${check.detail}` })));
      if (assertions(binding, response, "after").filter(check => check.detail.startsWith("after: preserved ")).some(check => !check.passed)) return response;
    }
    if (test.effect !== "read") {
      response.cleanup = evidence();
      const cleanupDeadline = Date.now() + 30_000;
      const cleanupBudget = () => {
        const budget = cleanupDeadline - Date.now();
        if (budget <= 0) throw new Error("Cleanup deadline exceeded");
        return budget;
      };
      await runConversation(host, provider, model, [binding.cleanup!], false, response.cleanup, response, { ...options, choices: false }, cleanupBudget);
      if (response.errors.length || response.blocked || conversationChecks(response.cleanup, binding, false).some(check => !check.passed)) return response;
      response.restored = await observeState(host, response.chatId, binding, cleanupBudget, "cleanup");
      response.observationChecks.push(...assertions(binding, response, "cleanup"));
    }
    if (response.observationChecks.every(check => check.passed)) response.continuation = "safe";
  } catch (error) { response.errors.push(`Task/observation failed: ${String(error)}`); }
  finally {
    try {
      response.logs = await ox<LogRow[]>(host, ["host", "logs", "--since", response.startedAt, "--all"], undefined, 10_000);
      if (!Array.isArray(response.logs)) throw new Error("Expected paginated log array");
    } catch (error) { response.errors.push(`Log collection failed: ${String(error)}`); response.continuation = "stop"; }
    response.totalMs = Date.now() - started;
  }
  return response;
}
