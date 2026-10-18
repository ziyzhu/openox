import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { defineDoc, type CommitChange, type ConversationId, type Cursor, type EntryRecord, type Harness, type JsonObject } from "@earendil-works/pi-durable";
import { ConversationFavorite, ConversationPresentation } from "./conversations";
import { ConversationApplicationMetadata } from "./install";
import { ProfileFileState } from "./file-store";

const context = BACKGROUND_CONTEXT;
const referenceDateOffsetSeconds = 978_307_200;
export type ConversationIndexRow = { at: number; pinned: boolean };
export interface ConversationIndexCursor { readonly profileID: string; readonly pinned: boolean; readonly at: number; readonly id: number }
type Ranked = ConversationIndexRow & { id: number };

export const ConversationIndex = defineDoc<{ rows: Record<string, ConversationIndexRow> }>({
  kind: "ox.conversation.index", version: 1, scope: "session",
  initial: () => ({ rows: {} }), checkpointWhen: (_, __, info) => info.deltasSinceBase >= 31,
});
const trackedKinds = new Set([ConversationPresentation.definition.kind, ConversationFavorite.definition.kind]);

function rank(left: Ranked, right: Ranked) {
  return Number(right.pinned) - Number(left.pinned) || right.at - left.at || right.id - left.id;
}
function messageTime(entry: EntryRecord) {
  if (entry.kind === "pi.reset" || entry.kind === "pi.compaction") return undefined;
  const times = (entry.model ?? []).flatMap(message => (message.role === "user" || message.role === "assistant")
    && Number.isFinite(message.timestamp) && message.timestamp > 0 ? [message.timestamp] : []);
  return times.length ? Math.max(...times) : undefined;
}
function holdsNativeTranscript(entry: EntryRecord) {
  const source = entry.kind === "ox.native.transcript" && entry.data && typeof entry.data === "object" && !Array.isArray(entry.data) ? entry.data.source : undefined;
  return !!source && typeof source === "object" && !Array.isArray(source) && Number(source.size) > 0;
}
function legacyTime(fields: JsonObject | undefined) {
  const seconds = [fields?.lastActivity, fields?.createdAt].find(value => typeof value === "number" && Number.isFinite(value));
  return typeof seconds === "number" ? (seconds + referenceDateOffsetSeconds) * 1_000 : 0;
}
function changedConversation(change: CommitChange) {
  if (change.type === "entry") return messageTime(change.value) === undefined ? undefined : change.value.conversationId;
  if (change.type === "document" && trackedKinds.has(change.record.kind)) return change.conversationId;
  return undefined;
}

export class ConversationIndexer {
  private harness: Harness;
  private profileID: string;
  private dirty = new Set<ConversationId>();
  private checked = new Set<ConversationId>();
  private flushing?: Promise<void>;
  private building?: Promise<Record<string, ConversationIndexRow>>;
  private unsubscribe: () => void;
  private onReport: (error: unknown) => void;

  constructor(harness: Harness, profileID: string, onReport: (error: unknown) => void) {
    this.harness = harness;
    this.profileID = profileID;
    this.onReport = onReport;
    this.unsubscribe = harness.subscribeCommits(publication => {
      for (const change of publication.changes) {
        const id = changedConversation(change);
        if (id !== undefined) this.dirty.add(id);
      }
      if (this.dirty.size) this.schedule();
    });
  }

  async close() {
    this.unsubscribe();
    this.dirty.clear();
    await this.flushing;
  }

  async lastMessageAt(id: ConversationId, fields: JsonObject | undefined) {
    const conversation = await this.harness.conversation(id, context);
    if (!conversation) return undefined;
    let cursor: Cursor | undefined;
    let size = 4;
    do {
      const page = await conversation.entries({}, size, cursor, context);
      for (const entry of page.items) {
        const at = messageTime(entry);
        if (at !== undefined) return at;
        if (holdsNativeTranscript(entry)) return legacyTime(fields);
      }
      cursor = page.next;
      size = 50;
    } while (cursor);
    return undefined;
  }

  async page(limit: number, cursor?: ConversationIndexCursor) {
    if (cursor && cursor.profileID !== this.profileID) throw new Error("Conversation list Profile mismatch");
    const rows = (await this.rows()).sort(rank);
    const start = cursor ? rows.findIndex(row => rank(cursor, row) < 0) : 0;
    const selected = start < 0 ? [] : rows.slice(start, start + limit);
    const last = selected.at(-1);
    const more = start >= 0 && start + limit < rows.length;
    return { rows: selected, next: more && last ? { profileID: this.profileID, pinned: last.pinned, at: last.at, id: last.id } : undefined };
  }

  refresh(id: ConversationId) {
    this.dirty.add(id);
    this.schedule();
  }

  async checkedAt(id: ConversationId, indexed: ConversationIndexRow, fields: JsonObject | undefined) {
    if (this.checked.has(id)) return indexed.at;
    const at = await this.lastMessageAt(id, fields);
    this.checked.add(id);
    if (at !== indexed.at) this.refresh(id);
    return at;
  }

  private async rows(): Promise<Ranked[]> {
    const stored = (await this.harness.snapshot(ConversationIndex, context))?.rows ?? await this.build();
    return Object.entries(stored).map(([id, row]) => ({ id: Number(id), ...row }));
  }

  private build() {
    this.building ??= (async () => {
      const ids: ConversationId[] = [];
      let cursor: Cursor | undefined;
      do {
        const page = await this.harness.commit(tx => tx.scanConversations({}, 100, cursor), context);
        ids.push(...page.items.map(record => record.id));
        cursor = page.next;
      } while (cursor);
      const rows: Record<string, ConversationIndexRow> = {};
      for (const [index, row] of (await Promise.all(ids.map(id => this.row(id)))).entries()) {
        if (row) rows[ids[index]!] = row;
      }
      await this.harness.commit(async tx => { (await tx.doc(ConversationIndex)).rows = rows; }, context);
      return rows;
    })().finally(() => { this.building = undefined; });
    return this.building;
  }

  private async row(id: ConversationId): Promise<ConversationIndexRow | undefined> {
    const [presentation, favorite, files, metadata] = await Promise.all([
      this.harness.snapshot(ConversationPresentation, id, context),
      this.harness.snapshot(ConversationFavorite, id, context),
      this.harness.snapshot(ProfileFileState, context),
      this.harness.snapshot(ConversationApplicationMetadata, id, context),
    ]);
    if (!presentation?.visible || files?.deletedConversations.includes(id)) return undefined;
    const at = await this.lastMessageAt(id, metadata?.fields);
    this.checked.add(id);
    return at === undefined ? undefined : { at, pinned: favorite?.favorite ?? false };
  }

  private schedule() {
    this.flushing ??= Promise.resolve().then(() => this.flush())
      .catch(error => this.onReport(error))
      .finally(() => { this.flushing = undefined; if (this.dirty.size) this.schedule(); });
  }

  private async flush() {
    while (this.dirty.size) {
      const ids = [...this.dirty];
      this.dirty.clear();
      if (!await this.harness.snapshot(ConversationIndex, context)) {
        if (!this.building) return;
        await this.building;
      }
      const rows = await Promise.all(ids.map(id => this.row(id)));
      await this.harness.commit(async tx => {
        const index = await tx.doc(ConversationIndex);
        for (const [position, id] of ids.entries()) {
          const row = rows[position];
          if (row) index.rows[id] = row; else delete index.rows[id];
        }
      }, context);
    }
  }
}
