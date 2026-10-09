import { hostContextText, activeHost, sameScope, type HostContext, type HostScope } from "./host-context";

export const defaultSoul = "## Voice\nBe warm, quietly competent, and a little dry. Sound like a capable teammate in a live conversation. Lead with the result, default to concise natural replies, and be direct about risks or disagreement. Match the user's tone and use judgment; style never overrides accuracy, safety, or the user's request.";
export interface ResponseLanguage { identifier: string; name: string }
export interface SystemPromptInput { soul: string; memory: string; hostContext?: HostContext }
export interface PromptScaffold { identity: string; operatingRules: string; skills: string }
export interface TurnState {
  skills: { name: string; description: string }[];
  skillConflicts: string[];
  attachedServices: { domain: string; description?: string; signIn: SignInState; fileMounts?: string[]; scope?: HostScope }[];
  hostContext?: HostContext;
  artifactPaths: string[];
  storageMode: "persisted" | "temporary";
  responseLanguage: ResponseLanguage | null;
}
type SignInState = "notRequired" | "signedIn" | "signedOut" | "authorized" | "notAuthorized" | "unknown";
const signInHints: Record<SignInState, string> = {
  notRequired: "no sign-in needed",
  signedIn: "signed in",
  signedOut: "signed out — public actions still work; only `requireAuth` actions need the user to sign in first",
  authorized: "authorized",
  notAuthorized: "not authorized — authorize this service before using it",
  unknown: "sign-in status still being checked — attempt the action; the error will say if sign-in is needed",
};
const temporaryStorage = "## Storage\nThis is a temporary conversation. You may read Profile-owned files, but cannot save changes to `MEMORY.md`, `SOUL.md`, `artifacts/`, or user skills. Selected external files under `files/<folder-id>/` are separate: they may still be changed when Files is attached and runtime approval is granted. Do not attempt blocked Profile mutations; continue with a transient answer or result.";
const temporaryProfileStorage = "## Storage\nThis is a temporary conversation. You may read Profile-owned files, but cannot save changes to `MEMORY.md`, `SOUL.md`, `artifacts/`, or user skills. Do not attempt blocked Profile mutations; continue with a transient answer or result.";
const join = (sections: string[]) => sections.filter(Boolean).join("\n\n");
const normalized = (text: string) => text.split(/\s+/u).filter(Boolean).join(" ");
const ordered = (a: string, b: string) => a < b ? -1 : a > b ? 1 : 0;

export function composeSystemPrompt(input: SystemPromptInput, scaffold: PromptScaffold) {
  if (typeof input?.soul !== "string" || typeof input?.memory !== "string") throw new Error("Prompt state requires soul and memory text");
  const { identity, operatingRules, skills } = scaffold;
  const sections = Object.fromEntries(Object.entries({ ox_identity: identity, ox_soul: input.soul,
    ox_rules: operatingRules, ox_skills: skills, ox_memory: `## Memory\n${input.memory}` })
    .filter(([, text]) => text.length > 0));
  return { scaffold: join([identity, operatingRules, skills]), soul: input.soul, memory: input.memory,
    sections, rendered: join(Object.values(sections)) };
}

export function responseDirective(language: ResponseLanguage | null) {
  if (language === null) return "";
  if (typeof language?.name !== "string" || typeof language?.identifier !== "string") throw new Error("Response language requires a name and identifier");
  return `## Language\nAlways reply in ${language.name} (${language.identifier}), no matter what language the user writes in, unless they explicitly ask for another language. Write every word of every reply — prose, lists, labels — in ${language.name}, and use local conventions for dates, numbers, and currency.`;
}

export function composeTurnContext(state: TurnState) {
  const skills = ["## Available Skills", ...[...state.skills].sort((a, b) => ordered(a.name, b.name))
    .map(skill => `- \`skills/${skill.name}/SKILL.md\` — ${normalized(skill.description)}`),
    ...state.skillConflicts.map(name => `- /${name}: choose a source in Skills before use.`)].join("\n");
  const host = state.hostContext ? activeHost(state.hostContext) : undefined;
  const services = state.attachedServices.length === 0 ? "" : ["## Attached Services",
    ...[...state.attachedServices].sort((a, b) => ordered(a.domain, b.domain)).flatMap(service => {
      const description = normalized(service.description ?? "");
      if (service.scope && (!state.hostContext || !state.hostContext.hosts.some(owner => sameScope(owner, service.scope!)))) throw new Error("Service owner is unavailable");
      const owner = service.scope && host && !sameScope(service.scope, host) ? ` [host=${JSON.stringify(service.scope.hostID)} profile=${JSON.stringify(service.scope.profileID)}]` : "";
      const line = `  - ${service.domain}${description ? ` — ${description}` : ""} [${signInHints[service.signIn]}]${owner}`;
      if (service.fileMounts === undefined) return [line];
      return [line, service.fileMounts.length === 0 ? "    - no folders are currently selected"
        : `    - selected folder mounts: ${[...service.fileMounts].sort().map(path => `\`${path}\``).join(", ")}`];
    })].join("\n");
  const artifacts = state.artifactPaths.length === 0 ? "" : ["## Conversation Artifacts", ...state.artifactPaths.map(path => `- \`${path}\``)].join("\n");
  const storage = host?.externalFiles === false ? temporaryProfileStorage : temporaryStorage;
  const content = join([skills, state.hostContext ? hostContextText(state.hostContext) : "", services, artifacts, state.storageMode === "temporary" ? storage : "", responseDirective(state.responseLanguage)]);
  return `<turn-state>\n${content}\n</turn-state>`;
}
