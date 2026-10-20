import { cases } from "./cases/index.ts";
import { randomUUID } from "node:crypto";
import { effectFor } from "./cases/functions.ts";
import { readers } from "./observations.ts";
import { coveredFunctions } from "./coverage.ts";
import type { CaseBinding, EvalCase, Fixture } from "./types.ts";

const object = (value: unknown): value is Record<string, unknown> => !!value && typeof value === "object" && !Array.isArray(value);
const strings = (value: unknown): value is string[] => Array.isArray(value) && value.every(item => typeof item === "string" && item.length > 0);

export function validateBinding(test: EvalCase, binding: CaseBinding): void {
  if (!object(binding) || typeof binding.context !== "string" || !binding.context.trim() || !object(binding.observations)
    || !Array.isArray(binding.assertions) || !Array.isArray(binding.actions) || !strings(binding.allowedActions)) throw new Error(`Incomplete QA binding: ${test.id}`);
  if (test.effect !== "read" && (typeof binding.cleanup !== "string" || !binding.cleanup.trim())) throw new Error(`Missing run-owned cleanup task: ${test.id}`);
  if (test.probe && (typeof binding.probeContext !== "string" || !binding.probeContext.trim())) throw new Error(`Missing independent probe inputs: ${test.id}`);
  for (const [key, reader] of Object.entries(binding.observations)) {
    if (["task", "probe"].includes(key) || !object(reader)) throw new Error(`Invalid observer: ${test.id}/${key}`);
    if (reader.phases && (!strings(reader.phases) || !reader.phases.length || reader.phases.some(phase => !["before", "after", "cleanup"].includes(phase)))) throw new Error(`Invalid observer phases: ${test.id}/${key}`);
    if (reader.kind === "vm") {
      if (!readers.has(reader.name) || !object(reader.args)) throw new Error(`Observer must use an approved read-only contract: ${test.id}/${key}`);
    } else if (reader.kind === "skill") {
      if (typeof reader.name !== "string" || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(reader.name)) throw new Error(`Invalid observed skill: ${test.id}/${key}`);
    } else if (reader.kind === "conversation") {
      if (typeof reader.id !== "string" && (!object(reader.id) || typeof reader.id.$receipt !== "string" || !strings(reader.id.path)) || !reader.id) throw new Error(`Missing observed conversation: ${test.id}/${key}`);
    } else if (reader.kind !== "cli" || !["providers", "conversations"].includes(reader.command)) throw new Error(`Invalid observer: ${test.id}/${key}`);
  }
  for (const rule of binding.assertions) {
    if (!object(rule) || !["before", "after", "probe", "cleanup"].includes(rule.phase) || !strings(rule.path)
      || !["equals", "includes", "unchanged", "absent"].includes(rule.operator) || typeof rule.evidence !== "string"
      || typeof rule.observation !== "string" || !["task", "probe", ...Object.keys(binding.observations)].includes(rule.observation)
      || ["equals", "includes"].includes(rule.operator) && !Object.hasOwn(rule, "expected")) throw new Error(`Invalid assertion: ${test.id}`);
    if (rule.operator === "unchanged" && rule.phase === "before") throw new Error(`Preconditions cannot compare themselves: ${test.id}`);
    if (rule.operator === "includes" && (rule.expected === "" || rule.expected === null || object(rule.expected) && !Object.keys(rule.expected).length || Array.isArray(rule.expected) && !rule.expected.length)) throw new Error(`Empty inclusion is not an outcome oracle: ${test.id}`);
    if (rule.phase === "probe" && (!test.probe || rule.observation !== "probe")) throw new Error(`Invalid fresh-context oracle: ${test.id}`);
    const reader = binding.observations[rule.observation];
    if (reader?.phases && rule.phase !== "probe" && (!reader.phases.includes(rule.phase) || rule.operator === "unchanged" && !reader.phases.includes("before"))) throw new Error(`Assertion lacks required observation phase: ${test.id}/${rule.observation}`);
  }
  for (const key of Object.keys(test.evidence)) {
    const phase = key === "condition" ? "before" : key === "cleanup" ? "cleanup" : key === "probe" ? "probe" : "after";
    if (!binding.assertions.some(rule => rule.evidence === key && rule.phase === phase
      && (key === "probe" || !["task", "probe"].includes(rule.observation))
      && (!["preserved", "cleanup"].includes(key) || rule.operator === "unchanged"))) throw new Error(`Missing independent ${key} oracle (${phase}): ${test.id}`);
  }
  if (test.probe && binding.assertions.some(rule => rule.phase === "probe" && typeof rule.expected === "string" && rule.expected.length > 3 && binding.probeContext!.includes(rule.expected))) throw new Error(`Probe exposes its expected answer: ${test.id}`);
  if (!binding.assertions.some(rule => rule.phase === "before" && !["task", "probe"].includes(rule.observation) && rule.operator === "equals")) throw new Error(`Missing explicit QA precondition: ${test.id}`);
  for (const action of binding.actions) {
    if (!object(action) || !binding.allowedActions.includes(action.name) || !["succeeded", "failed"].includes(action.outcome)
      || !Number.isInteger(action.minimum) || action.minimum < 0 || action.maximum !== undefined && (!Number.isInteger(action.maximum) || action.maximum < action.minimum)
      || action.args !== undefined && !object(action.args)) throw new Error(`Invalid Action expectation: ${test.id}`);
  }
  for (const name of coveredFunctions(test)) if (test.variant === "success" && !binding.actions.some(action => action.name === name && action.outcome === "succeeded" && action.minimum > 0)) throw new Error(`Missing successful function receipt: ${test.id}/${name}`);
  const known = new Set(cases.flatMap(coveredFunctions));
  for (const name of binding.allowedActions) if (!known.has(name) && name !== "ox.tool.help") throw new Error(`Unknown allowed Action: ${name}`);
  for (const name of binding.allowedActions.filter(name => effectFor(name) !== "read")) {
    if (!binding.actions.some(action => action.name === name)) throw new Error(`State-changing Action needs an explicit scoped expectation: ${test.id}/${name}`);
  }
  if (test.effect === "read" && binding.allowedActions.some(name => effectFor(name) !== "read")) throw new Error(`Read-only case cannot authorize writes or external effects: ${test.id}`);
}

export function validateFixture(value: unknown): Fixture {
  if (!object(value) || value.version !== 1 || typeof value.qaProfile !== "string" || !value.qaProfile.trim() || !object(value.cases)) throw new Error("Expected a version 1 fixture with a named QA Profile and case bindings");
  for (const [id, binding] of Object.entries(value.cases)) {
    const test = cases.find(entry => entry.id === id);
    if (!test) throw new Error(`Unknown fixture case: ${id}`);
    validateBinding(test, binding as CaseBinding);
  }
  return value as Fixture;
}

export function effects(test: EvalCase, binding: CaseBinding) {
  return new Set([test.effect, ...binding.allowedActions.map(effectFor)]);
}

export function fixtureTemplate(selected: EvalCase[], qaProfile: string) {
  const simple = new Set(["ox.app.info", "ox.app.profile", "ox.app.profiles", "ox.app.notifications", "ox.app.language", "ox.app.defaultModel", "ox.provider.default", "ox.provider.list", "ox.repository.list", "ox.schedule.list", "ox.secret.list"]);
  return { version: 1, qaProfile, cases: Object.fromEntries(selected.map(test => [test.id,
    ["evolve-create", "evolve-fresh-use"].includes(test.id) ? skillFixture(qaProfile, !!test.probe) :
    test.variant === "success" && test.function && simple.has(test.function) ? {
      context: "Report the actual current state concisely. Do not change files, configuration, accounts or services.",
      observations: { profile: { kind: "vm", name: "ox.app.profile", args: {} }, outcome: { kind: "vm", name: test.function, args: {} }, memory: { kind: "vm", name: "ox.fs.read", args: { path: "MEMORY.md" } } },
      assertions: [
        { evidence: "qa", phase: "before", observation: "profile", path: ["name"], operator: "equals", expected: qaProfile },
        { evidence: "qa", phase: "before", observation: "profile", path: ["storage"], operator: "equals", expected: "local" },
        { evidence: "outcome", phase: "after", observation: "outcome", path: [], operator: "unchanged" },
        { evidence: "preserved", phase: "after", observation: "memory", path: ["text"], operator: "unchanged" },
      ],
      actions: [{ name: test.function, outcome: "succeeded", minimum: 1 }],
      allowedActions: [test.function, "ox.app.profile", "ox.fs.read", "ox.tool.help"],
    } : {
      context: "", observations: {}, assertions: [], actions: [], allowedActions: [],
      ...(test.probe ? { probeContext: "" } : {}),
      ...(test.effect !== "read" ? { cleanup: "" } : {}), requirements: test.evidence,
    }])) };
}

function skillFixture(qaProfile: string, probe: boolean): CaseBinding {
  const name = `ox-eval-${randomUUID().replaceAll("-", "")}`;
  const prefix = randomUUID().replaceAll("-", "").slice(0, 12);
  const count = 2 + Math.floor(Math.random() * 4);
  const description = "Repeat a supplied text prefix a requested number of times.";
  const instructions = "When asked to repeat a prefix, reply with only the prefix repeated count times, without separators. Do not modify files or use services.";
  return {
    context: `Name: ${name}. Description exactly ${JSON.stringify(description)}. Instructions exactly ${JSON.stringify(instructions)}. Create only this Profile skill, with no dependencies or extra resources. Proceed without a separate proposal checkpoint. Preserve all unrelated files and settings.`,
    ...(probe ? { probeContext: `Read and use Profile skill ${name} with prefix ${prefix} and count ${count}.` } : {}),
    observations: {
      profile: { kind: "vm", name: "ox.app.profile", args: {} },
      memory: { kind: "vm", name: "ox.fs.read", args: { path: "MEMORY.md" } },
      soul: { kind: "vm", name: "ox.fs.read", args: { path: "SOUL.md" } },
      providers: { kind: "vm", name: "ox.provider.list", args: {} },
      defaults: { kind: "vm", name: "ox.app.defaultModel", args: {} },
      language: { kind: "vm", name: "ox.app.language", args: {} },
      policies: { kind: "vm", name: "ox.app.actionPolicies", args: { limit: 100 } },
      inventory: { kind: "vm", name: "ox.fs.glob", args: { path: "skills", pattern: `${name}/**/*` } },
      package: { kind: "skill", name, phases: ["after"] },
    },
    assertions: [
      { evidence: "qa", phase: "before", observation: "profile", path: ["name"], operator: "equals", expected: qaProfile },
      { evidence: "qa", phase: "before", observation: "inventory", path: ["paths"], operator: "equals", expected: [] },
      { evidence: "outcome", phase: "after", observation: "inventory", path: ["paths"], operator: "equals", expected: [`skills/${name}/SKILL.md`] },
      { evidence: "outcome", phase: "after", observation: "package", path: [], operator: "equals", expected: { name, description, instructions, services: [], resources: {} } },
      ...["profile", "memory", "soul", "providers", "defaults", "language", "policies"].flatMap(observation => (["after", "cleanup"] as const).map(phase => ({ evidence: phase === "after" ? "preserved" : "cleanup", phase, observation, path: [], operator: "unchanged" as const }))),
      { evidence: "cleanup", phase: "cleanup", observation: "inventory", path: ["paths"], operator: "unchanged" },
      ...(probe ? [{ evidence: "probe", phase: "probe" as const, observation: "probe", path: ["answer"], operator: "equals" as const, expected: prefix.repeat(count) }] : []),
    ],
    actions: [{ name: "ox.skill.create", outcome: "succeeded", minimum: 1, maximum: 1, args: { name } }, { name: "ox.skill.delete", outcome: "succeeded", minimum: 0, maximum: 1, args: { name } }],
    allowedActions: ["ox.fs.read", "ox.fs.list", "ox.fs.glob", "ox.fs.grep", "ox.skill.create", "ox.skill.delete", "ox.user.choose", "ox.user.progress", "ox.tool.help"],
    cleanup: `Delete only the run-owned Profile skill ${name}. Preserve all other state; report any blocked deletion without trying another method.`,
  };
}
