import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { oxScaffold, composeOxPrompt } from "../src/core/ox-prompts";
import { composeTurnSections, filesSection, responseDirective, renderSections, type TurnState } from "../src/core/prompts";
import { deviceContextText, type DeviceContext, type PromptDevice } from "../src/core/device-context";
import { executeGuidance, countWords } from "../src/core/tool-prompts";
import { guidanceTexts } from "../src/core/guidance-texts";
import { functionGuidance } from "../src/functions/guidance";
import { providerIdentities } from "../src/core/provider-prompts";
import { bundledSkills } from "../src/core/bundled-skills";
import { runtimeEvent, outputTruncation, imageReadGuidance, failureReceipt } from "../src/core/runtime-prompts";
import { standardServiceActions } from "../src/functions/service/standard-actions";

export type Scope = "system" | "execute" | "help" | "runtime";
export interface Unit {
  id: string; group: string; title: string; source: string; scope: Scope; editable: boolean; current: string;
  fragments: (text: string) => string[];
}
export interface Variant {
  presentation: "conversation-bubbles" | "text"; storage: "persisted" | "temporary" | "temporaryProfile";
  language: boolean; files: boolean; folders: boolean; multiHost: boolean; identity: boolean; isolated: boolean;
}
export interface Rendered { identity: string; system: string; execute: string }

export const repo = join(import.meta.dir, "../../..");
const agent = join(import.meta.dir, "..");
const functionsDir = join(agent, "src/functions");
const commonFunctions = ["ox.fs.read", "ox.fs.edit", "ox.fs.write", "ox.web.search", "ox.web.fetch", "ox.service.inspect", "ox.service.invoke"];
const catalogNamespaces = ["conversation", "provider", "repository", "secret", "service", "user", "web", "fs", "output", "skill", "schedule", "vision"];
const catalogSentinel = "\u0000CATALOG\u0000";
const nativeFacts = [
  ["timeoutSeconds", "apps/shared/Runtime/VM/VirtualMachine.swift", /defaultTimeout: TimeInterval = ([\d_]+)/],
  ["maxLines", "apps/shared/Runtime/Conversations/JavaScriptOutputStore.swift", /static let maxLines = ([\d_]+)/],
  ["maxKiB", "apps/shared/Runtime/Conversations/JavaScriptOutputStore.swift", /static let maxBytes = ([\d_]+) \* 1024/],
  ["maxFetches", "apps/shared/Runtime/Services/Web/WebFunctions.swift", /static let maxFetches = ([\d_]+)/],
  ["maxTransientAttachments", "apps/shared/Runtime/Services/Web/WebFunctions.swift", /static let maxTransientAttachments = ([\d_]+)/],
] as const;
const limits = Object.fromEntries(nativeFacts.map(([key, file, pattern]) => {
  const match = readFileSync(join(repo, file), "utf8").match(pattern);
  if (!match) throw new Error(`Cannot read native prompt limit ${key} from ${file}`);
  return [key, Number(match[1]!.replaceAll("_", ""))];
})) as Record<typeof nativeFacts[number][0], number>;
const sentinels: [string, string, string][] = [
  ["999001", "{timeoutSeconds}", String(limits.timeoutSeconds)], ["999002", "{maxLines}", String(limits.maxLines)],
  ["999003", "{maxKiB}", String(limits.maxKiB)], ["999004", "{maxFetches}", countWords[limits.maxFetches] ?? String(limits.maxFetches)],
  ["999005", "{maxTransientAttachments}", countWords[limits.maxTransientAttachments] ?? String(limits.maxTransientAttachments)],
];
const languageExample = { identifier: "zh-Hans", name: "Simplified Chinese" };

const normalized = (text: string) => text.split(/\s+/u).filter(Boolean).join(" ");
const escapeXml = (text: string) => text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&apos;");
const declaration = (text: string) => text.replace(/: `await [^`]+`/g, "").replace(/`await (ox\.[\w.]+)\([^`]*\)`/g, "`$1`").replace(/`(ox\.[\w.]+)\([^`]*\)`/g, "`$1`").replaceAll("*/", "*\\/");
const fillLimits = (text: string) => sentinels.reduce((value, [, placeholder, real]) => value.replaceAll(placeholder, real), text);

export function catalogSummary(description: string) {
  const line = normalized(description);
  const usage = [": `", ": await ", " before calling await ", " with `{"].map(marker => line.indexOf(marker)).filter(index => index >= 0);
  const endings = [". ", "? ", "! "].map(marker => line.indexOf(marker)).filter(index => index >= 0);
  const summary = usage.length ? line.slice(0, Math.min(...usage)) : endings.length ? line.slice(0, Math.min(...endings) + 1) : line;
  return /[.?!]$/.test(summary) ? summary : `${summary}.`;
}

function locate(path: string, needle: string) {
  const rel = relative(repo, path);
  const lines = readFileSync(path, "utf8").split("\n");
  const probe = needle.slice(0, 40);
  const index = lines.findIndex(line => line.includes(probe));
  return index >= 0 ? `${rel}:${index + 1}` : rel;
}

function readContracts() {
  const contracts: Record<string, { description: string; file: string }> = {};
  for (const entry of readdirSync(functionsDir, { withFileTypes: true }).filter(entry => entry.isDirectory())) {
    const file = join(functionsDir, entry.name, "contracts.json");
    const parsed = JSON.parse(readFileSync(file, "utf8")) as Record<string, { description?: string }>;
    for (const [name, contract] of Object.entries(parsed)) if (contract.description) contracts[name] = { description: contract.description, file };
  }
  return contracts;
}

export const contracts = readContracts();

function executeTemplate() {
  const raw = executeGuidance({ catalog: catalogSentinel, timeoutSeconds: 999001, maxLines: 999002, maxBytes: 999003 * 1024, maxFetches: 999004, maxTransientAttachments: 999005 });
  const template = sentinels.reduce((value, [sentinel, placeholder]) => value.replaceAll(sentinel, placeholder), raw);
  const paragraphs: string[] = [];
  let open = false;
  for (const part of template.split("\n\n")) {
    if (open) paragraphs[paragraphs.length - 1] += `\n\n${part}`; else paragraphs.push(part);
    if ((part.match(/```/g) ?? []).length % 2 === 1) open = !open;
  }
  return { template, paragraphs };
}

const execute = executeTemplate();
const executeNames = [
  ["intro", "Run JavaScript as an async function body."],
  ["discovery", "The catalog contains summaries, not full contracts."],
  ["standard", "Call standard service actions through ox.service.invoke"],
  ["handoffs", "Use service handoffs for login"],
  ["batching", "Batch independent reads with Promise.allSettled"],
  ["state", "Each execution is self-contained;"],
  ["budget", "Service actions and user handoffs do not consume"],
  ["output", "Combined console and return output is limited"],
] as const;

function catalog() {
  const namespaces = catalogNamespaces.map(name => `ox.${name} — ${guidanceTexts[`namespace.${name}`]}`);
  const functions = Object.entries(contracts).map(([name, contract]) => `${name} — ${catalogSummary(contract.description)}`).sort();
  return [...namespaces, "", ...functions].join("\n");
}

const sampleRoot = ["MEMORY.md", "app", "conversations", "mounts", "repositories", "skills", "tmp", "reports"].map(name => ({ name, directory: name !== "MEMORY.md" }));

function files(variant: Variant) {
  return filesSection(sampleRoot, variant.folders ? [{ path: "mounts/icloud-notes", name: "iCloud Drive › Notes" }] : [], "conversations/42/");
}

const iosScope = { deviceID: "ios", profileID: "local" };
const macHost: PromptDevice = { deviceID: "mac", profileID: "work", functions: ["ox"], serviceKinds: ["web", "api", "mcp"], presentation: "text", externalFiles: true };

function deviceContext(variant: Variant): DeviceContext {
  const host: PromptDevice = { ...iosScope, functions: ["ox"], serviceKinds: ["web", "ios", "mcp"], presentation: variant.presentation, externalFiles: variant.storage !== "temporaryProfile" };
  return { active: iosScope, devices: variant.multiHost ? [host, macHost] : [host] };
}

function turnState(variant: Variant, context: DeviceContext): TurnState {
  return {
    skills: [...bundledSkills], skillConflicts: [],
    filePaths: variant.files ? ["conversations/42/photo.jpg", "reports/q3.pdf"] : [],
    storageMode: variant.storage === "persisted" ? "persisted" : "temporary", responseLanguage: variant.language ? languageExample : null, deviceContext: context,
  };
}

export function render(variant: Variant): Rendered {
  const context = deviceContext(variant);
  const input = { memory: "(MEMORY.md contents)", deviceContext: context };
  const base = composeOxPrompt(input, variant.isolated);
  const turn = composeTurnSections(turnState(variant, context), oxScaffold, context);
  const system = renderSections({ ...base.sections, ...turn, files: files(variant) });
  return {
    identity: variant.identity ? providerIdentities["claude-subscription"]! : "",
    system,
    execute: fillLimits(execute.template).replace(catalogSentinel, catalog()),
  };
}

function textUnit(id: string, group: string, title: string, source: string, scope: Scope, current: string, fragments: (text: string) => string[] = text => [text], editable = true): Unit {
  return { id, group, title, source, scope, editable, current, fragments };
}

export const defaultVariant: Variant = {
  presentation: "conversation-bubbles", storage: "persisted", language: false, files: false, folders: false, multiHost: false, identity: false, isolated: false,
};

function turnSections(patch: Partial<Variant>) {
  const variant = { ...defaultVariant, ...patch };
  const context = deviceContext(variant);
  return composeTurnSections(turnState(variant, context), oxScaffold, context);
}

function buildUnits(): Unit[] {
  const core = (file: string) => join(agent, "src/core", file);
  const prompts = core("prompts.ts");
  const empty = turnSections({});
  const bubbles = empty.replies!;
  const textReplies = turnSections({ presentation: "text" }).replies!;
  const temporary = turnSections({ storage: "temporary" }).storage!;
  const temporaryProfile = turnSections({ storage: "temporaryProfile" }).storage!;
  const deviceFooter = deviceContextText(deviceContext(defaultVariant)).split("\n").at(-1)!;
  const directive = responseDirective({ identifier: "{identifier}", name: "{name}" });
  const fillDirective = (text: string) => [text.replaceAll("{identifier}", languageExample.identifier).replaceAll("{name}", languageExample.name)];
  const isolated = composeOxPrompt({ memory: "", deviceContext: deviceContext(defaultVariant) }, true).sections.durable_test_files!;
  const units: Unit[] = [
    textUnit("identity.claude-subscription", "System", "Provider identity (Claude subscription)", locate(core("provider-prompts.ts"), "claude-subscription"), "system", providerIdentities["claude-subscription"]!),
    textUnit("preamble", "System", "Preamble", locate(core("ox-prompts.ts"), "preamble:"), "system", oxScaffold.preamble),
    textUnit("rules", "System", "Rules", locate(core("ox-prompts.ts"), "rules:"), "system", oxScaffold.rules),
    textUnit("skills.intro", "System", "Skills intro", locate(core("ox-prompts.ts"), "skills:"), "system", oxScaffold.skills),
    ...bundledSkills.map(skill => textUnit(`skill.${skill.name}`, "System · skill descriptions", skill.name,
      locate(join(agent, "skills", skill.name, "SKILL.md"), "description:"), "system", skill.description,
      text => [`<description>${escapeXml(normalized(text))}</description>`])),
    textUnit("devices.footer", "System · turn state", "Devices footer", locate(core("device-context.ts"), deviceFooter), "system", deviceFooter),
    textUnit("replies.bubbles", "System · turn state", "Replies (conversation bubbles)", locate(prompts, "Replies render as Markdown"), "system", bubbles),
    textUnit("replies.text", "System · turn state", "Replies (text)", locate(prompts, "Replies render as text"), "system", textReplies),
    textUnit("files.none", "System · turn state", "No conversation files", locate(prompts, empty.conversation_files!), "system", empty.conversation_files!),
    textUnit("files.tree", "System · turn state", "Profile file tree", locate(prompts, "export function filesSection"), "system", files(defaultVariant), text => [text], false),
    textUnit("storage.persisted", "System · turn state", "Storage (saved)", locate(prompts, "const persistedStorage"), "system", empty.storage!),
    textUnit("storage.temporary", "System · turn state", "Storage (temporary)", locate(prompts, "const temporaryStorage"), "system", temporary!),
    textUnit("storage.temporaryProfile", "System · turn state", "Storage (temporary, no external files)", locate(prompts, "const temporaryProfileStorage"), "system", temporaryProfile!),
    textUnit("language.default", "System · turn state", "Language (default)", locate(prompts, "Reply in the language"), "system", empty.language!),
    textUnit("language.directive", "System · turn state", "Language (fixed)", locate(prompts, "Always reply in"), "system", directive, fillDirective),
    textUnit("durable_test_files", "System · turn state", "Isolated session files", locate(core("ox-prompts.ts"), "const isolatedFiles"), "system", isolated),
  ];
  const prose = execute.paragraphs.filter(paragraph => !paragraph.includes(catalogSentinel)
    && !paragraph.startsWith("Common built-in functions:") && !paragraph.startsWith("Standard action contracts:"));
  prose.forEach((paragraph, index) => {
    const name = executeNames.find(([, prefix]) => paragraph.startsWith(prefix))?.[0] ?? `p${index + 1}`;
    units.push(textUnit(`execute.${name}`, "Execute · prose", `Execute: ${name}`, locate(core("tool-prompts.ts"), paragraph.slice(0, 40)), "execute", paragraph, text => [fillLimits(text)]));
  });
  for (const name of catalogNamespaces) {
    const key = `namespace.${name}`;
    const file = name === "output" ? core("guidance-texts.ts") : join(functionsDir, name, "guidance.ts");
    units.push(textUnit(`ns.${name}`, "Execute · catalog namespaces", `ox.${name}`, locate(file, `"${key}"`), "execute", guidanceTexts[key]!, text => [`ox.${name} — ${text}`]));
  }
  for (const [kind, actions] of Object.entries(standardServiceActions)) for (const action of actions) {
    units.push(textUnit(`std.${kind}.${action.id}`, "Execute · standard actions", `${kind}: ${action.id}`, locate(join(functionsDir, "service/standard-actions.json"), action.description), "execute", action.description, text => [`/** ${text} */`]));
  }
  for (const [name, contract] of Object.entries(contracts).sort(([a], [b]) => a < b ? -1 : 1)) {
    const common = commonFunctions.includes(name);
    const namespace = name.split(".").slice(0, 2).join(".");
    const guidanceFile = join(functionsDir, name.split(".")[1]!, "guidance.ts");
    const sources = [locate(contract.file, `"${name}"`), ...(Object.hasOwn(functionGuidance, name) ? [locate(guidanceFile, `"${name}"`)] : [])].join(" + ");
    units.push(textUnit(`fn.${name}`, `Functions · ${namespace}`, name, sources, common ? "execute" : "help", contract.description,
      text => [`${name} — ${catalogSummary(text)}`, ...(common ? [`/** ${declaration(text)} */`] : [])]));
  }
  const runtimeFile = core("runtime-prompts.ts");
  const guidanceFile = core("guidance-texts.ts");
  units.push(
    textUnit("runtime.login.loggedIn", "Runtime messages", "Login event (logged in)", locate(runtimeFile, "The user just"), "runtime", runtimeEvent({ type: "serviceLogin", domain: "{domain}", authorized: false })),
    textUnit("runtime.login.authorized", "Runtime messages", "Login event (authorized)", locate(runtimeFile, "The user just"), "runtime", runtimeEvent({ type: "serviceLogin", domain: "{domain}", authorized: true })),
    textUnit("runtime.receipt", "Runtime messages", "Failure receipt (example)", locate(runtimeFile, "Execution receipt"), "runtime",
      failureReceipt({ invocations: [{ id: "c1", name: "ox.service.invoke", state: "succeeded" }, { id: "c2", name: "ox.fs.write", state: "failed" }, { id: "c3", name: "ox.web.fetch", state: "running" }], omittedCalls: 2 }), undefined, false),
    textUnit("runtime.truncation", "Runtime messages", "Output truncation", locate(runtimeFile, "Tool output truncated"), "runtime",
      outputTruncation({ path: "{path}", maxLines: 999002, maxBytes: 999003 * 1024 }).trim().replaceAll("999002", "{maxLines}").replaceAll("999003", "{maxKiB}")),
    textUnit("runtime.imageRead", "Runtime messages", "Image read guidance", locate(runtimeFile, "for local OCR"), "runtime", imageReadGuidance({ path: "{path}" })),
    ...["image.fileRead", "file.conversion", "output.cacheExceeded", "output.expired"].map(key => textUnit(`runtime.${key}`, "Runtime messages", key, locate(guidanceFile, `"${key}"`), "runtime", guidanceTexts[key]!)),
  );
  return units;
}

export const units = buildUnits();

export function apply(variant: Variant, drafts: Map<string, string>) {
  const old = render(variant);
  const next: Rendered = { ...old };
  const appears: Record<string, boolean> = {};
  const all = `${old.identity}\n${old.system}\n${old.execute}`;
  for (const unit of units) {
    const before = unit.fragments(unit.current);
    appears[unit.id] = unit.scope !== "help" && unit.scope !== "runtime" ? before.every(fragment => all.includes(fragment)) : false;
    const draft = drafts.get(unit.id);
    if (draft === undefined || !appears[unit.id]) continue;
    const after = unit.fragments(draft);
    before.forEach((fragment, index) => {
      for (const key of ["identity", "system", "execute"] as const) next[key] = next[key].split(fragment).join(after[index] ?? "");
    });
  }
  return { old, next, appears };
}
