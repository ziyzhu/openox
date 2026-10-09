import { isDeepStrictEqual } from "node:util";
import { parseSkill } from "../../../../packages/protocol/src/skills.ts";
import { newChat, ox, vmCall } from "./cli.ts";
import type { ChatEvidence, Check, EvalCase, EvalResponse, EvalSnapshot, Invocation, ObservedState } from "./types.ts";

export function render(value: string, fixture: EvalResponse["fixture"]): string {
  return fixture ? value.replaceAll("{{name}}", fixture.name).replaceAll("{{answer}}", fixture.answer) : value;
}

export async function observeState(host: string, provider: string, model: string, test: EvalCase, remaining: () => number, qaProfile?: string): Promise<ObservedState> {
  const chatId = await newChat(host, provider, model, true, remaining());
  const state: ObservedState = { chatId, values: {}, files: {} };
  const fields = {
    profile: ["name", "storage"], defaultModel: ["configured", "region", "provider", "model", "thinkingLevel", "supportsTools", "authentication"],
    language: ["selection", "locale"], theme: ["selection", "appearance"], actionPolicies: ["defaultPolicy", "resolved", "overrides", "truncated"],
  };
  for (const [name, required] of Object.entries(fields)) {
    const value = await vmCall<Record<string, unknown>>(host, chatId, `ox.app.${name}`, name === "actionPolicies" ? { limit: 100 } : {}, remaining());
    if (typeof value !== "object" || Array.isArray(value) || !required.every(field => field in value && (value[field] !== null || ["thinkingLevel", "defaultPolicy", "resolved"].includes(field)))
      || value.truncated === true) throw new Error(`Incomplete ${name} observation`);
    state.values[name] = value;
  }
  const profile = state.values.profile as { name?: string; storage?: string };
  if (!profile.name || !profile.storage || qaProfile && (profile.name !== qaProfile || profile.storage !== "local")) throw new Error("Expected the named local QA Profile; no mutation is authorized here");
  const providers = await ox(host, ["host", "providers"], undefined, remaining());
  if (!Array.isArray(providers)) throw new Error("Incomplete provider catalog");
  state.values.providers = providers;
  const artifacts = await vmCall<{ items: unknown[]; truncated: boolean }>(host, chatId, "ox.fs.list", { path: "artifacts", options: { limit: 100 } }, remaining());
  if (!Array.isArray(artifacts.items) || artifacts.truncated !== false) throw new Error("Incomplete artifact inventory");
  state.values.artifacts = artifacts.items;
  const skills = await vmCall<{ paths: string[]; truncated: boolean }>(host, chatId, "ox.fs.glob", { path: "skills", pattern: "**/*", options: { limit: 1000 } }, remaining());
  if (!Array.isArray(skills.paths) || skills.truncated !== false || skills.paths.some(path => !path.startsWith("skills/"))) throw new Error("Incomplete skill inventory");
  let bytes = 0;
  for (const path of ["MEMORY.md", "SOUL.md", ...skills.paths]) {
    const text = await readText(host, chatId, path, remaining());
    bytes += Buffer.byteLength(text);
    if (bytes > 1_048_576) throw new Error("Observed files exceed the 1 MiB evidence budget");
    state.files[path] = text;
  }
  if (test.workflow?.kind === "readSkill") {
    state.guide = await readText(host, chatId, test.workflow.path, remaining());
    if (!state.guide.trim()) throw new Error("Missing independent skill contents");
  }
  return state;
}

async function readText(host: string, chatId: string, path: string, timeoutMs: number): Promise<string> {
  const file = await vmCall<{ path: string; text: string | null; truncated: boolean; unsupported: string | null }>(host, chatId, "ox.fs.read", { path, options: { maxBytes: 1_048_576 } }, timeoutMs);
  if (file.path !== path || typeof file.text !== "string" || file.truncated !== false || file.unsupported) throw new Error(`Incomplete text observation: ${path}`);
  return file.text;
}

export async function requireCleanupPolicy(host: string, state: ObservedState, remaining: () => number): Promise<void> {
  for (const action of ["ox.skill.create", "ox.skill.delete"]) {
    const policy = await vmCall<{ resolved: { action: string; policy: string } | null }>(host, state.chatId, "ox.app.actionPolicies", { action }, remaining());
    if (policy.resolved?.action !== action || policy.resolved.policy !== "allow") throw new Error(`QA policy must already allow ${action}; no policies were changed`);
  }
}

export function preserved(before: ObservedState, after: ObservedState, fixture?: EvalResponse["fixture"]): Check[] {
  const files = (state: ObservedState) => Object.fromEntries(Object.entries(state.files).filter(([path]) => !fixture || !path.startsWith(`skills/${fixture.name}/`)));
  return [
    { detail: "Observed Profile, provider catalog, settings, policies, and artifact inventory preserved", passed: isDeepStrictEqual(before.values, after.values) },
    { detail: "Observed memory, soul, and unrelated skill packages preserved", passed: isDeepStrictEqual(files(before), files(after)) },
  ];
}

export function actions(snapshot: EvalSnapshot | undefined): Invocation[] {
  return (snapshot?.blocks ?? []).flatMap(block => block.kind.trace?.entries.flatMap(entry => entry.invocation ? [entry.invocation] : []) ?? []);
}

const readActions = new Set([
  "ox.fs.list", "ox.fs.read", "ox.fs.glob", "ox.fs.grep", "ox.tool.help", "ox.user.reportProgress",
  "ox.app.info", "ox.app.profile", "ox.app.profiles", "ox.app.language", "ox.app.theme", "ox.app.model",
  "ox.app.defaultModel", "ox.app.actionPolicies", "ox.app.repositories", "ox.app.logs", "ox.provider.get",
]);

export function ownedSkillWrite(call: Invocation, name: string): boolean {
  return call.name === "ox.skill.create" && call.args.name === name
    || ["ox.fs.write", "ox.fs.edit"].includes(call.name) && typeof call.args.path === "string" && call.args.path.startsWith(`skills/${name}/`);
}

export function permittedActions(evidence: ChatEvidence, fixture?: EvalResponse["fixture"]): Check[] {
  return [{ detail: "Only read-only/diagnostic Actions or authorized run-owned skill writes executed", passed: actions(evidence.snapshot).every(call => readActions.has(call.name) || !!fixture && ownedSkillWrite(call, fixture.name)) }];
}

export function skillMatches(test: EvalCase, response: EvalResponse): boolean {
  if (test.workflow?.kind !== "createSkill" || !response.fixture || !response.after) return false;
  const { name } = response.fixture;
  const text = response.after.files[`skills/${name}/SKILL.md`];
  if (text === undefined) return false;
  try {
    const skill = parseSkill(text, name);
    return skill.description === test.workflow.description && skill.instructions === render(test.workflow.instructions, response.fixture)
      && skill.services.length === 0 && Object.keys(response.after.files).filter(path => path.startsWith(`skills/${name}/`)).length === 1;
  } catch { return false; }
}
