/** Host-neutral entry: no runtime shims, native globals, or application chat binding required. */
export { openOxAgentSession, OxAgentSession, type SessionOptions, type CommittedEvent } from "./core/session";
export { ProfileFiles, ProfileFile, ProfileIndex, ProfileArtifact, canonical } from "./core/profile-files";
export { profileEnv } from "./core/profile-env";
export { OxConversations, ConversationPresentation, ConversationFavorite, ConversationReadState,
  type ConversationReference, type ConversationListCursor, type ConversationHistoryCursor, type PresentationChange } from "./core/conversations";
export type { ArtifactFiles, ArtifactRecord } from "./core/artifacts";
export type { AuthorizeFile } from "./core/file-tools";
