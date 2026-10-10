import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { AgentDoc, defineDoc, type ConversationId, type Cursor, type EntryId, type Harness } from "@earendil-works/pi-durable";
import { WorkspaceState } from "./workspace";

/** Pi IDs are database-local. Application references always include their owning Profile. */
export interface ConversationReference { readonly profileID: string; readonly conversationID: ConversationId }
export interface ConversationListCursor { readonly profileID: string; readonly pi: Cursor }
export interface ConversationHistoryCursor extends ConversationReference { readonly pi: Cursor }
export interface PresentationChange { title?: string; visible?: boolean; favorite?: boolean }

// Presentation is current application state, not rewindable transcript state. Forks inherit the
// current title/visibility, but start unfavorited and unread. Internal conversations create none
// of these documents. Every 32nd ordinary change checkpoints the bounded latest-only delta tail.
const checkpointWhen = (_: unknown, __: unknown, info: { deltasSinceBase: number }) => info.deltasSinceBase >= 31;
export const ConversationPresentation = defineDoc<{ title: string; visible: boolean }>({
  kind: "ox.conversation.presentation", version: 1, scope: "conversation", history: "latest", fork: "current",
  initial: () => ({ title: "", visible: false }), checkpointWhen,
});
export const ConversationFavorite = defineDoc<{ favorite: boolean }>({
  kind: "ox.conversation.favorite", version: 1, scope: "conversation", history: "latest", fork: "initial",
  initial: () => ({ favorite: false }), checkpointWhen,
});
export const ConversationReadState = defineDoc<{ lastReadEntryID: number | null }>({
  kind: "ox.conversation.read", version: 1, scope: "conversation", history: "latest", fork: "initial",
  initial: () => ({ lastReadEntryID: null }), checkpointWhen,
});
const context = BACKGROUND_CONTEXT;
function pageSize(limit: number) {
  if (!Number.isInteger(limit) || limit < 1 || limit > 100) throw new Error("Page size must be between 1 and 100");
  return limit;
}

/** Application semantics over Pi's existing Session APIs; no registry, transcript or model copy. */
export class OxConversations {
  readonly profileID: string;
  private harness: Harness;
  private ready: () => void;

  constructor(profileID: string, harness: Harness, ready: () => void) {
    this.profileID = profileID;
    this.harness = harness;
    this.ready = ready;
  }

  reference(conversationID: ConversationId): ConversationReference {
    const reference = { profileID: this.profileID, conversationID };
    this.id(reference);
    return reference;
  }
  id(reference: ConversationReference): ConversationId {
    // Scope rejection is deliberately before readiness, handle acquisition, or any Pi lookup.
    if (reference.profileID !== this.profileID) throw new Error("Conversation Profile mismatch");
    if (!Number.isSafeInteger(reference.conversationID) || reference.conversationID < 0) throw new Error("Invalid Pi conversation ID");
    this.ready();
    return reference.conversationID;
  }
  private async handle(reference: ConversationReference) {
    const id = this.id(reference);
    if ((await this.harness.snapshot(WorkspaceState, context))?.deletedConversations.includes(id)) throw new Error("Conversation not found");
    const conversation = await this.harness.conversation(id, context);
    if (!conversation) throw new Error("Conversation not found");
    return conversation;
  }

  async present(reference: ConversationReference, change: PresentationChange = { visible: true }) {
    const conversation = await this.handle(reference);
    if (change.title !== undefined && (typeof change.title !== "string" || change.title.length > 1024)) throw new Error("Invalid conversation title");
    if (change.visible !== undefined && typeof change.visible !== "boolean") throw new Error("Invalid conversation visibility");
    if (change.favorite !== undefined && typeof change.favorite !== "boolean") throw new Error("Invalid conversation favorite");
    await conversation.commit(async tx => {
      const presentation = await tx.doc(ConversationPresentation, conversation.id);
      if (change.title !== undefined) presentation.title = change.title;
      if (change.visible !== undefined) presentation.visible = change.visible;
      if (change.favorite !== undefined) (await tx.doc(ConversationFavorite, conversation.id)).favorite = change.favorite;
    }, context);
  }

  async markRead(reference: ConversationReference, entryID: EntryId | null) {
    const conversation = await this.handle(reference);
    if (entryID !== null) {
      if (!Number.isSafeInteger(entryID) || entryID < 0) throw new Error("Invalid read entry ID");
      const page = await conversation.entries({ minEntryId: entryID, maxEntryId: entryID }, 1, undefined, context);
      if (!page.items.length) throw new Error("Read entry is not visible in this conversation");
    }
    await conversation.commit(async tx => { (await tx.doc(ConversationReadState, conversation.id)).lastReadEntryID = entryID; }, context);
  }

  async metadata(reference: ConversationReference) {
    const conversation = await this.handle(reference);
    const [record, presentation, favorite, readState, agent, newest] = await Promise.all([
      this.harness.commit(tx => tx.conversation(conversation.id), context),
      this.harness.snapshot(ConversationPresentation, conversation.id, context),
      this.harness.snapshot(ConversationFavorite, conversation.id, context),
      this.harness.snapshot(ConversationReadState, conversation.id, context),
      this.harness.snapshot(AgentDoc, conversation.id, context),
      conversation.entries({}, 1, undefined, context),
    ]);
    return { reference: this.reference(conversation.id), record, presentation,
      favorite: favorite?.favorite ?? false, readState: readState ?? { lastReadEntryID: null }, agent,
      unread: !!newest.items.length && (readState?.lastReadEntryID ?? -1) < newest.items[0]!.id };
  }

  /** A page scans at most `limit` Pi records. Hidden records can yield an empty page with `next`. */
  async list(limit = 100, cursor?: ConversationListCursor) {
    if (cursor && cursor.profileID !== this.profileID) throw new Error("Conversation list Profile mismatch");
    this.ready();
    const page = await this.harness.commit(tx => tx.scanConversations({}, pageSize(limit), cursor?.pi), context);
    const deleted = (await this.harness.snapshot(WorkspaceState, context))?.deletedConversations ?? [];
    const metadata = await Promise.all(page.items.filter(record => !deleted.includes(record.id)).map(record => this.metadata(this.reference(record.id))));
    return { items: metadata.filter(item => item.presentation?.visible),
      next: page.next ? { profileID: this.profileID, pi: page.next } : undefined };
  }

  /** Full immutable, newest-first, fork-aware history, including entries excluded by reset/compaction.
   * Round-trip only this page's scoped cursor. This is NOT Conversation.context() or an active snapshot.
   */
  async history(reference: ConversationReference, limit = 100, cursor?: ConversationHistoryCursor) {
    this.id(reference);
    if (cursor && (cursor.profileID !== reference.profileID || cursor.conversationID !== reference.conversationID)) {
      throw new Error("Conversation history cursor scope mismatch");
    }
    pageSize(limit);
    const conversation = await this.handle(reference);
    const page = await conversation.entries({}, limit, cursor?.pi, context);
    return { reference: this.reference(conversation.id), order: "newest-first" as const, items: page.items,
      next: page.next ? { ...this.reference(conversation.id), pi: page.next } : undefined };
  }
}
