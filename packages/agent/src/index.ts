/** Host-neutral entry: no runtime shims, native globals, or application chat binding required. */
export { openProfileRuntime, ProfileRuntime, type ProfileRuntimeOptions, type CommittedEvent } from "./profile/runtime";
export { ProfileFiles, ProfileFile, ProfileIndex, ProfileArtifact, canonical } from "./profile/files";
export { profileEnv } from "./profile/filesystem";
export { composeSystemPrompt, composeTurnContext, responseDirective, defaultSoul,
  type SystemPromptInput, type PromptScaffold, type TurnState, type ResponseLanguage } from "./core/prompts";
export { websiteInstructions, providerIdentity } from "./core/provider-prompts";
export { composeOxPrompt, portableScaffold, oxScaffold } from "./core/ox-prompts";
export { activeHost, sameScope, hostContextText, type HostScope, type PromptHost, type HostContext } from "./core/host-context";
export { executeGuidance, type ExecuteGuidanceInput } from "./core/tool-prompts";
export { runtimeEvent, failureReceipt, outputTruncation, imageReadGuidance, type RuntimeEvent } from "./core/runtime-prompts";
export { guidanceText } from "./core/guidance-texts";
export { OxConversations, ConversationPresentation, ConversationFavorite, ConversationReadState,
  type ConversationReference, type ConversationListCursor, type ConversationHistoryCursor, type PresentationChange } from "./profile/conversations";
export type { ArtifactFiles, ArtifactRecord } from "./profile/artifacts";
export type { AuthorizeFile } from "./profile/tools";
export { installOxProfile, ConversationApplicationMetadata, type NormalizedProfileDraft, type ProfileInstallHost } from "./profile/install";
export { ApplicationPresentation, type ApplicationPresentationChange, type ApplicationAgentChange } from "./profile/presentation";
