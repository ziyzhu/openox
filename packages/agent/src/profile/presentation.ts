import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { JsonValue } from "@earendil-works/chord";
import type { ModelThinkingLevel } from "@earendil-works/pi-ai";
import { AgentDoc, type ConversationId, type Cursor, type EntryDraft, type EntryRecord, type JsonObject, type Tx } from "@earendil-works/pi-durable";
import { ConversationFavorite, ConversationPresentation, ConversationReadState, type ConversationReference, type ConversationListCursor, type ConversationHistoryCursor } from "./conversations";
import { ConversationApplicationMetadata } from "./install";
import type { ProfileRuntime } from "./runtime";

const context = BACKGROUND_CONTEXT;
export interface ApplicationAgentChange {
  model?: { modelId: string; provider?: string } | null;
  thinkingLevel?: ModelThinkingLevel | null;
}
export interface ApplicationPresentationChange {
  agent?: ApplicationAgentChange;
  metadata?: JsonObject;
  title?: string;
  favorite?: boolean;
  unread?: boolean;
  turns?: JsonValue[];
}
const reserved = new Set(["id", "profileID", "conversationID", "identity", "agent", "model", "title", "favorite", "unread", "read", "readState", "presentation", "isFavorite", "hasUnreadResponse", "lastReadEntryID"]);
function validate(change: ApplicationPresentationChange) {
  if (change.metadata !== undefined && (!change.metadata || Array.isArray(change.metadata) || typeof change.metadata !== "object" || Object.keys(change.metadata).some(key => reserved.has(key)))) {
    throw new Error("Application metadata cannot duplicate conversation identity or Pi choices");
  }
  if (change.title !== undefined && (typeof change.title !== "string" || change.title.length > 1024)) throw new Error("Invalid conversation title");
  if (change.favorite !== undefined && typeof change.favorite !== "boolean") throw new Error("Invalid conversation favorite");
  if (change.unread !== undefined && typeof change.unread !== "boolean") throw new Error("Invalid conversation unread state");
  if (change.turns !== undefined && (!Array.isArray(change.turns) || change.turns.some(turn => !turnID(turn)))) throw new Error("Presentation turns require stable IDs");
  if (change.agent !== undefined) {
    if (!change.agent || typeof change.agent !== "object" || Object.keys(change.agent).some(key => !["model", "thinkingLevel"].includes(key))) throw new Error("Invalid application agent choices");
    if (change.agent.model != null && (!change.agent.model.modelId || typeof change.agent.model.modelId !== "string")) throw new Error("Invalid canonical model ID");
    if (change.agent.thinkingLevel != null && !["off", "minimal", "low", "medium", "high", "xhigh", "max"].includes(change.agent.thinkingLevel)) throw new Error("Invalid Pi thinking level");
  }
}
function turnID(turn: JsonValue | undefined): string | undefined {
  return turn && typeof turn === "object" && !Array.isArray(turn) && typeof turn.id === "string" && turn.id ? turn.id : undefined;
}
function canonicalJSON(value: JsonValue): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonicalJSON(value[key]!)}`).join(",")}}`;
  return JSON.stringify(value);
}
async function ledger(tx: Tx, conversationID: ConversationId) {
  const entries: EntryRecord[] = [];
  let cursor: Cursor | undefined;
  do {
    const page = await tx.scanEntries({ conversationId: conversationID }, 100, cursor);
    entries.push(...page.items); cursor = page.next;
  } while (cursor);
  return entries.reverse();
}
async function presentation(tx: Tx, id: ConversationId, change: ApplicationPresentationChange, latest: number | null, visible?: boolean) {
  const state = await tx.doc(ConversationPresentation, id);
  if (visible !== undefined) state.visible = visible;
  if (change.title !== undefined) state.title = change.title;
  if (change.metadata !== undefined) {
    const metadata = await tx.doc(ConversationApplicationMetadata, id);
    const native = Object.fromEntries(Object.entries(metadata.fields).filter(([key]) => ["nativeProviderID", "nativeReasoningEffort"].includes(key)));
    metadata.fields = { ...native, ...change.metadata };
  }
  if (change.favorite !== undefined) (await tx.doc(ConversationFavorite, id)).favorite = change.favorite;
  if (change.unread !== undefined) (await tx.doc(ConversationReadState, id)).lastReadEntryID = change.unread ? null : latest;
}
export class ApplicationPresentation {
  private runtime: ProfileRuntime;

  constructor(runtime: ProfileRuntime) {
    this.runtime = runtime;
  }
  private async hasTranscript(reference: ConversationReference) {
    let cursor: ConversationHistoryCursor | undefined;
    do {
      const page = await this.runtime.conversations.history(reference, 1, cursor);
      if (page.items.some(entry => entry.kind !== "pi.reset" && entry.kind !== "pi.compaction"
        && entry.model?.some(message => message.role === "user" || message.role === "assistant"))) return true;
      cursor = page.next;
    } while (cursor);
    return false;
  }
  async list(limit = 100, cursor?: ConversationListCursor) {
    const page = await this.runtime.conversations.list(limit, cursor);
    const items = await Promise.all(page.items.map(async state => {
      const [metadata, hasTranscript] = await Promise.all([
        this.runtime.harness.snapshot(ConversationApplicationMetadata, state.reference.conversationID, context),
        this.hasTranscript(state.reference),
      ]);
      return { reference: state.reference, presentation: state.presentation, favorite: state.favorite, unread: state.unread,
        agent: { model: state.agent?.model, thinkingLevel: state.agent?.thinkingLevel }, metadata: metadata?.fields ?? {}, hasTranscript };
    }));
    return { items, next: page.next };
  }
  private async agentChange(tx: Tx, id: ConversationId, change: ApplicationAgentChange, requireIdle: boolean) {
    const state = await tx.doc(AgentDoc, id);
    const provider = state.model?.provider.startsWith("ox-native:") ? state.model.provider
      : change.model?.provider?.startsWith("ox-native:") ? change.model.provider : `ox-native:${this.runtime.conversations.profileID}:${id}`;
    const model = change.model === undefined ? state.model : change.model === null ? undefined : { provider, modelId: change.model.modelId };
    const thinkingLevel = change.thinkingLevel === undefined ? state.thinkingLevel : change.thinkingLevel ?? undefined;
    const changed = state.model?.provider !== model?.provider || state.model?.modelId !== model?.modelId || state.thinkingLevel !== thinkingLevel;
    if (requireIdle && changed) {
      for (const status of ["pending", "running", "waiting", "completing"] as const) {
        if ((await tx.scanTasks({ conversationId: id, status }, 1)).items.length) throw new Error("Conversation must be idle to change model choices");
      }
    }
    if (model === undefined) delete state.model; else state.model = model;
    if (thinkingLevel === undefined) delete state.thinkingLevel; else state.thinkingLevel = thinkingLevel;
  }
  async create(change: ApplicationPresentationChange & { entries?: EntryDraft[] }) {
    validate(change);
    if (change.entries !== undefined && (!Array.isArray(change.entries) || change.entries.some(entry => !entry.kind || (entry.head !== undefined && entry.head !== "self") || entry.edits !== undefined))) throw new Error("New conversations require current entries without foreign database IDs");
    const frozen = JSON.parse(JSON.stringify(change)) as typeof change;
    const conversation = await this.runtime.harness.createConversation({ ownership: { kind: "ownerless" }, init: async (tx, id) => {
      if (frozen.agent) await this.agentChange(tx, id, frozen.agent, false);
      let latest: number | null = null;
      for (const entry of frozen.entries ?? []) latest = (await tx.appendEntry(id, entry)).id;
      if (latest === null) latest = (await tx.appendEntry(id, { kind: "ox.native.presentation", data: {} })).id;
      await presentation(tx, id, { metadata: frozen.metadata ?? {}, title: frozen.title ?? "", favorite: frozen.favorite ?? false, unread: frozen.unread ?? false }, latest, true);
    } }, context);
    return { conversationID: conversation.id, reference: this.runtime.conversations.reference(conversation.id) };
  }
  async load(reference: ConversationReference) {
    const id = this.runtime.conversations.id(reference);
    const conversation = await this.runtime.harness.conversation(id, context);
    if (!conversation) throw new Error("Conversation not found");
    const [state, metadata, entries, active] = await Promise.all([
      this.runtime.conversations.metadata(reference),
      this.runtime.harness.snapshot(ConversationApplicationMetadata, id, context),
      this.runtime.harness.commit(tx => ledger(tx, id), context),
      conversation.context(context),
    ]);
    return { ...state, metadata: metadata?.fields ?? {}, entries, messages: active.messages };
  }
  async save(reference: ConversationReference, change: ApplicationPresentationChange) {
    validate(change);
    const frozen = JSON.parse(JSON.stringify(change)) as ApplicationPresentationChange;
    const id = this.runtime.conversations.id(reference);
    const conversation = await this.runtime.harness.conversation(id, context);
    if (!conversation) throw new Error("Conversation not found");
    await conversation.commit(async tx => {
      if (frozen.agent) await this.agentChange(tx, id, frozen.agent, true);
      const entries = await ledger(tx, id);
      const turns = new Map<string, JsonValue>();
      for (const entry of entries) {
        if (entry.kind !== "ox.native.presentation" && entry.kind !== "ox.native.turn") continue;
        const turn = entry.data && typeof entry.data === "object" && !Array.isArray(entry.data) ? entry.data.turn : undefined;
        const key = turnID(turn);
        if (key) turns.set(key, turn!);
      }
      let latest = entries.at(-1)?.id ?? null;
      for (const turn of frozen.turns ?? []) {
        const key = turnID(turn)!;
        if (turns.has(key) && canonicalJSON(turns.get(key)!) === canonicalJSON(turn)) continue;
        latest = (await tx.appendEntry(id, { kind: "ox.native.presentation", data: { turn } })).id;
        turns.set(key, turn);
      }
      await presentation(tx, id, frozen, latest);
    }, context);
  }
  async delete(reference: ConversationReference) { await this.runtime.conversations.present(reference, { visible: false }); }
}
