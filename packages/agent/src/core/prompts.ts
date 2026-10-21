import { hostContextText, activeHost, sameScope, type HostContext, type HostScope } from "./host-context";

export interface ResponseLanguage { identifier: string; name: string }
export interface SystemPromptInput { memory: string; hostContext?: HostContext }
export interface PromptScaffold { preamble: string; rules: string; skills: string }
export interface TurnState {
  skills: { name: string; description: string }[];
  skillConflicts: string[];
  attachedServices: { domain: string; description?: string; signIn: SignInState; scope?: HostScope }[];
  fileMounts?: string[];
  hostContext?: HostContext;
  filePaths: string[];
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
const persistedStorage = "This conversation is saved to the Profile.";
const temporaryStorage = "This is a temporary conversation. You may read Profile-owned files, but cannot save changes to Profile files, including `MEMORY.md` or user skills. Selected external files under `files/<folder-id>/` are separate: they may still be changed with runtime approval. Do not attempt blocked Profile mutations; continue with a transient answer or result.";
const temporaryProfileStorage = "This is a temporary conversation. You may read Profile-owned files, but cannot save changes to Profile files, including `MEMORY.md` or user skills. Do not attempt blocked Profile mutations; continue with a transient answer or result.";
const normalized = (text: string) => text.split(/\s+/u).filter(Boolean).join(" ");
const ordered = (a: string, b: string) => a < b ? -1 : a > b ? 1 : 0;
const escapeXml = (text: string) => text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&apos;");

export function renderSections(sections: Record<string, string>) {
  return Object.entries(sections).map(([key, text]) => key === "preamble" ? text : `<${key}>\n${text}\n</${key}>`).join("\n\n");
}

export function composeSystemPrompt(input: SystemPromptInput, scaffold: PromptScaffold) {
  if (typeof input?.memory !== "string") throw new Error("Prompt state requires memory text");
  const sections: Record<string, string> = { preamble: scaffold.preamble, rules: scaffold.rules, memory: input.memory };
  return { scaffold: renderSections({ preamble: scaffold.preamble, rules: scaffold.rules }), memory: input.memory, sections, rendered: renderSections(sections) };
}

export function responseDirective(language: ResponseLanguage | null) {
  if (language === null) return "";
  if (typeof language?.name !== "string" || typeof language?.identifier !== "string") throw new Error("Response language requires a name and identifier");
  return `Always reply in ${language.name} (${language.identifier}), no matter what language the user writes in, unless they explicitly ask for another language. Write every word of every reply — prose, lists, labels — in ${language.name}, and use local conventions for dates, numbers, and currency.`;
}

export function composeTurnSections(state: TurnState, scaffold: PromptScaffold, fallbackHost?: HostContext): Record<string, string> {
  const hostContext = state.hostContext ?? fallbackHost;
  const host = hostContext ? activeHost(hostContext) : undefined;
  const skills = [scaffold.skills, "", "<available_skills>", ...[...state.skills].sort((a, b) => ordered(a.name, b.name)).flatMap(skill => [
    "  <skill>", `    <name>${escapeXml(skill.name)}</name>`, `    <description>${escapeXml(normalized(skill.description))}</description>`,
    `    <location>skills/${escapeXml(skill.name)}/SKILL.md</location>`, "  </skill>"]), "</available_skills>",
    ...state.skillConflicts.map(name => `/${name}: choose a source in Skills before use.`)].join("\n");
  const replies = host?.presentation === "conversation-bubbles"
    ? "Replies render as Markdown conversation bubbles. Put ![title](path) on its own line to show a file inline, or use a direct public image URL. Link supporting files with [title](path). A fenced mermaid block renders as a diagram."
    : "Replies render as text with Markdown support. Link supporting files with [title](path).";
  const services = state.attachedServices.length === 0 ? "No services are attached." : [...state.attachedServices].sort((a, b) => ordered(a.domain, b.domain)).map(service => {
    const description = normalized(service.description ?? "");
    if (service.scope && (!hostContext || !hostContext.hosts.some(owner => sameScope(owner, service.scope!)))) throw new Error("Service owner is unavailable");
    const owner = service.scope && host && !sameScope(service.scope, host) ? ` [host=${JSON.stringify(service.scope.hostID)} profile=${JSON.stringify(service.scope.profileID)}]` : "";
    return `- ${service.domain}${description ? ` — ${description}` : ""} [${signInHints[service.signIn]}]${owner}`;
  }).join("\n");
  const folders = state.fileMounts?.length ? [...state.fileMounts].sort().map(path => `- \`${path}/\``).join("\n")
    : "No folders are granted to this Profile. The user can add folders on the Profile's Files page.";
  const files = state.filePaths.length === 0 ? "No files are attached to this conversation." : state.filePaths.map(path => `- \`${path}\``).join("\n");
  const storage = state.storageMode === "persisted" ? persistedStorage : host?.externalFiles === false ? temporaryProfileStorage : temporaryStorage;
  return { skills, hosts: hostContext ? hostContextText(hostContext) : "No host context is available.", replies, attached_services: services,
    conversation_files: files, mounted_folders: folders, storage, language: responseDirective(state.responseLanguage) || "Reply in the language the user writes in." };
}
