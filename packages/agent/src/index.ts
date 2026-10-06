/** Host-neutral entry: no runtime shims, native globals, or application chat binding required. */
export { openOxAgentSession, OxAgentSession, type SessionOptions, type CommittedEvent } from "./core/session";
export { ProfileFiles, ProfileFile, ProfileIndex, ProfileArtifact, canonical } from "./core/profile-files";
export { profileEnv } from "./core/profile-env";
export { composeSystemPrompt, composeTurnContext, responseDirective, defaultSoul,
  type SystemPromptInput, type PromptScaffold, type TurnState, type ResponseLanguage } from "./core/prompts";
export { websiteInstructions, providerIdentity } from "./core/provider-prompts";
export { composeOxPrompt, portableScaffold, oxScaffold } from "./core/ox-prompts";
export { activeHost, sameScope, hostContextText, type HostScope, type PromptHost, type HostContext } from "./core/host-context";
export { executeGuidance, type ExecuteGuidanceInput } from "./core/tool-prompts";
export { runtimeEvent, failureReceipt, outputTruncation, imageReadGuidance, type RuntimeEvent } from "./core/runtime-prompts";
export { guidanceText } from "./core/guidance-texts";
export { OxConversations, ConversationPresentation, ConversationFavorite, ConversationReadState,
  type ConversationReference, type ConversationListCursor, type ConversationHistoryCursor, type PresentationChange } from "./core/conversations";
export type { ArtifactFiles, ArtifactRecord } from "./core/artifacts";
export type { AuthorizeFile } from "./core/file-tools";
export { installOxProfile, ConversationApplicationMetadata, type NormalizedProfileDraft, type ProfileInstallHost } from "./core/profile-install";
export { ApplicationPresentation, type ApplicationPresentationChange, type ApplicationAgentChange } from "./core/application-presentation";
