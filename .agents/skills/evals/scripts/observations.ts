import { isDeepStrictEqual } from "node:util";
import { parseSkill } from "../../../../packages/protocol/src/skills.ts";
import { ox, vmCall } from "./cli.ts";
import type { Assertion, CaseBinding, Check, EvalResponse, EvalSnapshot, ObservedState, Reader } from "./types.ts";

export const readers = new Set([
  "ox.app.info", "ox.app.profile", "ox.app.profiles", "ox.app.notifications", "ox.app.language", "ox.app.theme", "ox.app.defaultModel", "ox.app.actionPolicies", "ox.app.logs",
  "ox.conversation.model", "ox.provider.default", "ox.provider.list", "ox.provider.get", "ox.provider.models", "ox.repository.list", "ox.repository.conflicts",
  "ox.repository.git.status", "ox.repository.git.log", "ox.repository.git.show", "ox.repository.git.diff", "ox.service.list", "ox.service.find", "ox.service.inspect", "ox.service.listAttached",
  "ox.fs.read", "ox.fs.list", "ox.fs.glob", "ox.fs.grep", "ox.schedule.list", "ox.secret.list",
  "ox.web.browser.getPageInfo", "ox.web.browser.getNavigationHistory", "ox.web.browser.listCapturedEvents",
]);

export function at(value: unknown, path: string[]): unknown {
  for (const key of path) {
    if (!value || typeof value !== "object" || !Object.hasOwn(value, key)) return undefined;
    value = (value as Record<string, unknown>)[key];
  }
  return value;
}

export function includes(value: unknown, expected: unknown): boolean {
  if (typeof value === "string" && typeof expected === "string") return value.includes(expected);
  if (Array.isArray(value)) return value.some(item => isDeepStrictEqual(item, expected));
  if (value && expected && typeof value === "object" && typeof expected === "object" && !Array.isArray(expected)) {
    return Object.entries(expected).every(([key, child]) => isDeepStrictEqual(at(value, [key]), child));
  }
  return false;
}

export function actions(snapshot?: EvalSnapshot) {
  return (snapshot?.blocks ?? []).flatMap(block => block.kind.trace?.entries.flatMap(entry => entry.invocation ? [entry.invocation] : []) ?? []);
}

function complete(value: unknown): boolean {
  if (Array.isArray(value)) return value.every(complete);
  if (value && typeof value === "object") return !Object.entries(value).some(([key, child]) =>
    ["truncated", "recognizedTextTruncated", "hasMore"].includes(key) && child === true
    || ["dropped", "evicted", "omittedInvocations"].includes(key) && typeof child === "number" && child > 0
    || !complete(child));
  return true;
}

async function observe(host: string, chatId: string, reader: Reader, remaining: () => number): Promise<unknown> {
  if (reader.kind === "vm") return vmCall(host, chatId, reader.name, reader.args, remaining());
  if (reader.kind === "skill") {
    const file = await vmCall<{ text: string; truncated: boolean; unsupported: string | null }>(host, chatId, "ox.fs.read", { path: `skills/${reader.name}/SKILL.md` }, remaining());
    if (!file || typeof file.text !== "string" || file.truncated !== false || file.unsupported) throw new Error("Missing complete skill text");
    return parseSkill(file.text, reader.name);
  }
  if (reader.kind === "conversation") return ox(host, ["conversation", "inspect", "--full"], reader.id === "{{task}}" ? chatId : reader.id, remaining());
  return ox(host, reader.command === "providers" ? ["host", "providers"] : ["conversation", "list"], undefined, remaining());
}

export async function observeState(host: string, chatId: string, binding: CaseBinding, remaining: () => number, phase: "before" | "after" | "cleanup"): Promise<ObservedState> {
  const state: ObservedState = { values: {} };
  let bytes = 0;
  for (const [name, reader] of Object.entries(binding.observations)) {
    if (reader.phases && !reader.phases.includes(phase)) continue;
    const value = await observe(host, chatId, reader, remaining);
    if (value === undefined || !complete(value)) throw new Error(`Missing or incomplete observation: ${name}`);
    bytes += Buffer.byteLength(JSON.stringify(value));
    if (bytes > 1_048_576) throw new Error(`Observations exceed total evidence budget at ${name}`);
    state.values[name] = value;
  }
  return state;
}

export function assertions(binding: CaseBinding, response: EvalResponse, phase: Assertion["phase"]): Check[] {
  const state = phase === "before" ? response.before : phase === "after" ? response.after : phase === "cleanup" ? response.restored : undefined;
  return binding.assertions.filter(rule => rule.phase === phase).map(rule => {
    const snapshot = rule.observation === "probe" ? response.probe?.snapshot : rule.observation === "task" ? response.snapshot : undefined;
    const answer = snapshot?.messages.flatMap(message => message.assistant ? [message.assistant] : []).at(-1)?.content.flatMap(block => block.text ? [block.text.text] : []).join("\n").trim();
    const value = snapshot ? { ...snapshot, answer } : state?.values[rule.observation];
    const actual = at(value, rule.path);
    const baseline = at(response.before?.values[rule.observation], rule.path);
    const parent = at(value, rule.path.slice(0, -1));
    const passed = rule.operator === "absent" ? rule.path.length > 0 && actual === undefined && !!parent && typeof parent === "object"
      : actual !== undefined && (rule.operator === "equals" ? isDeepStrictEqual(actual, rule.expected)
        : rule.operator === "includes" ? includes(actual, rule.expected) : baseline !== undefined && isDeepStrictEqual(actual, baseline));
    return { detail: `${phase}: ${rule.evidence} (${rule.observation}/${rule.path.join("/")}, ${rule.operator})`, passed };
  });
}
