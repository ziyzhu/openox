export const defaultSoul = "## Voice\nBe warm, quietly competent, and a little dry. Sound like a capable teammate in a live chat. Lead with the result, default to concise natural replies, and be direct about risks or disagreement. Match the user's tone and use judgment; style never overrides accuracy, safety, or the user's request.";
export interface ResponseLanguage { identifier: string; name: string }
export interface SystemPromptInput { soul: string; memory: string }
export interface PromptScaffold { identity: string; operatingRules: string; skills: string }
export interface TurnState {
  skills: { name: string; description: string }[];
  skillConflicts: string[];
  attachedServices: { domain: string; description?: string; signIn: SignInState }[];
  fileMountPaths: string[];
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
const temporaryStorage = "## Storage\nThis is a temporary chat. You may read Profile-owned files, but cannot save changes to `MEMORY.md`, `SOUL.md`, `artifacts/`, or user skills. Selected external files under `files/<folder-id>/` are separate: they may still be changed when Files is attached and runtime approval is granted. Do not attempt blocked Profile mutations; continue with a transient answer or result.";
const join = (sections: string[]) => sections.filter(Boolean).join("\n\n");
const normalized = (text: string) => text.split(/\s+/u).filter(Boolean).join(" ");
const ordered = (a: string, b: string) => a < b ? -1 : a > b ? 1 : 0;

export function composeSystemPrompt(input: SystemPromptInput, scaffold: PromptScaffold) {
  if (typeof input?.soul !== "string" || typeof input?.memory !== "string") throw new Error("Prompt state requires soul and memory text");
  const { identity, operatingRules, skills } = scaffold;
  return { scaffold: join([identity, operatingRules, skills]), soul: input.soul, memory: input.memory,
    rendered: join([identity, input.soul, operatingRules, skills, `## Memory\n${input.memory}`]) };
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
  const services = state.attachedServices.length === 0 ? "" : ["## Attached Services",
    ...[...state.attachedServices].sort((a, b) => ordered(a.domain, b.domain)).flatMap(service => {
      const description = normalized(service.description ?? "");
      const line = `  - ${service.domain}${description ? ` — ${description}` : ""} [${signInHints[service.signIn]}]`;
      if (service.domain !== "ios:files") return [line];
      return [line, state.fileMountPaths.length === 0 ? "    - no folders are currently selected"
        : `    - selected folder mounts: ${[...state.fileMountPaths].sort().map(path => `\`${path}\``).join(", ")}`];
    })].join("\n");
  const artifacts = state.artifactPaths.length === 0 ? "" : ["## Chat Artifacts", ...state.artifactPaths.map(path => `- \`${path}\``)].join("\n");
  const content = join([skills, services, artifacts, state.storageMode === "temporary" ? temporaryStorage : "", responseDirective(state.responseLanguage)]);
  return `<turn-state>\n${content}\n</turn-state>`;
}
