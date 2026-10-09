import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import type { Message } from "@earendil-works/pi-ai";
import { defineDoc, type AgentChange, type EntryDraft, type EntryRecord, type Cursor, type JsonObject } from "@earendil-works/pi-durable";
import type { SqliteDatabase } from "@earendil-works/pi-durable/storage/sqlite";
import { artifactPath, artifactRecord, type ArtifactFiles, type ArtifactRecord } from "./artifacts";
import { canonical, ProfileArtifact, ProfileIndex } from "./files";
import { openProfileRuntime, type ProfileRuntime } from "./runtime";
import type { ConversationReference } from "./conversations";

export interface NormalizedProfileDraft {
  format: 1;
  profileID: string;
  documents: { path: string; text: string }[];
  artifacts: (ArtifactRecord & { binary: boolean; saved: boolean })[];
  payloads?: ArtifactRecord[];
  conversations: {
    key: string;
    title: string;
    favorite: boolean;
    unread: boolean;
    agent: Pick<AgentChange, "model" | "thinkingLevel" | "instructions" | "cwd">;
    metadata?: JsonObject;
    entries: EntryDraft[];
    expectedContext: Message[];
  }[];
}
export interface ProfileInstallHost {
  database: SqliteDatabase;
  artifacts: ArtifactFiles;
  conversations?: AsyncIterable<NormalizedProfileDraft["conversations"][number]>;
}
export const ConversationApplicationMetadata = defineDoc<{ fields: JsonObject }>({
  kind: "ox.conversation.metadata", version: 1, scope: "conversation", history: "latest", fork: "current",
  initial: () => ({ fields: {} }), checkpointWhen: (_, __, info) => info.deltasSinceBase >= 31,
});
const context = BACKGROUND_CONTEXT;
const same = (left: unknown, right: unknown): boolean => {
  if (Object.is(left, right)) return true;
  if (!left || !right || typeof left !== "object" || typeof right !== "object") return false;
  if (Array.isArray(left) !== Array.isArray(right)) return false;
  const a = Object.entries(left).sort(([a], [b]) => a.localeCompare(b));
  const b = Object.entries(right).sort(([a], [b]) => a.localeCompare(b));
  return a.length === b.length && a.every(([key, value], index) => key === b[index]![0] && same(value, b[index]![1]));
};
function validate(draft: NormalizedProfileDraft) {
  if (draft.format !== 1 || !draft.profileID) throw new Error("Unsupported normalized Profile draft");
  const paths = new Set<string>();
  for (const file of draft.documents) {
    if (canonical(file.path) !== file.path || (!/^(MEMORY\.md|SOUL\.md|skill-selections\.json)$/.test(file.path) && !file.path.startsWith("skills/"))) {
      throw new Error("Invalid Profile document path");
    }
    if (paths.has(file.path) || typeof file.text !== "string") throw new Error("Invalid or duplicate Profile document");
    paths.add(file.path);
  }
  const artifacts = new Set<string>();
  for (const file of draft.artifacts) {
    artifactRecord(file, artifactPath(file.path), file.size);
    if (artifacts.has(file.path) || typeof file.binary !== "boolean" || typeof file.saved !== "boolean") throw new Error("Invalid or duplicate Profile artifact");
    artifacts.add(file.path);
  }
  const payloads = new Map<string, ArtifactRecord>();
  for (const file of draft.payloads ?? []) {
    artifactRecord(file, artifactPath(file.path), file.size);
    if (file.path !== `artifacts/payload-${file.sha256}.json` || !Number.isSafeInteger(file.size) || file.size < 0 || payloads.has(file.path) || artifacts.has(file.path)) {
      throw new Error("Invalid or duplicate Profile payload");
    }
    payloads.set(file.path, file);
  }
  const payload = (value: unknown): void => {
    if (Array.isArray(value)) { value.forEach(payload); return; }
    if (!value || typeof value !== "object") return;
    const fields = value as Record<string, unknown>;
    const candidate = fields.oxPayload;
    if (candidate && typeof candidate === "object" && !Array.isArray(candidate) && (candidate as { format?: unknown }).format === 1) {
      const reference = candidate as { source?: ArtifactRecord; offset?: number; length?: number };
      const record = reference?.source && payloads.get(reference.source.path);
      if (!record || !same(record, reference!.source) || !Number.isSafeInteger(reference!.offset) || !Number.isSafeInteger(reference!.length)
          || reference!.offset! < 0 || reference!.length! < 0 || reference!.offset! > record.size || reference!.length! > record.size - reference!.offset!) {
        throw new Error("Payload is not declared in the owning Profile");
      }
    }
    Object.values(fields).forEach(payload);
  };
  const attachment = (value: unknown): void => {
    if (Array.isArray(value)) { value.forEach(attachment); return; }
    if (!value || typeof value !== "object") return;
    const fields = value as Record<string, unknown>;
    if ("oxAttachment" in fields) {
      if (typeof fields.oxAttachment !== "string" || fields.oxProfileID !== draft.profileID || !artifacts.has(artifactPath(`artifacts/${fields.oxAttachment}`))) {
        throw new Error("Attachment is not declared in the owning Profile");
      }
    }
    Object.values(fields).forEach(attachment);
  };
  const keys = new Set<string>();
  return (conversation: NormalizedProfileDraft["conversations"][number]) => {
    if (!conversation.key || keys.has(conversation.key)) throw new Error("Invalid or duplicate source conversation key");
    keys.add(conversation.key);
    if (Object.keys(conversation.metadata ?? {}).some(key => ["id", "profileID", "conversationID", "model", "title", "isFavorite", "hasUnreadResponse"].includes(key))) {
      throw new Error("Application metadata cannot duplicate conversation identity or Pi choices");
    }
    for (const entry of conversation.entries) {
      if (!entry.kind || (entry.head !== undefined && entry.head !== "self") || entry.edits !== undefined) throw new Error("Normalized entries cannot reference source database IDs");
      attachment(entry.model);
      payload(entry.data);
      if (entry.data && typeof entry.data === "object" && !Array.isArray(entry.data) && entry.data.source !== undefined) {
        const source = entry.data.source as unknown as ArtifactRecord;
        if (!same(payloads.get(source.path), source)) throw new Error("Missing source archive payload");
      }
    }
    attachment(conversation.expectedContext);
  };
}
async function history(session: ProfileRuntime, reference: ConversationReference) {
  const entries: EntryRecord[] = [];
  let cursor: Cursor | undefined;
  const conversation = (await session.harness.conversation(reference.conversationID, context))!;
  do {
    const page = await conversation.entries({}, 100, cursor, context);
    entries.push(...page.items); cursor = page.next;
  } while (cursor);
  return entries.reverse();
}
async function verifyFiles(session: ProfileRuntime, draft: NormalizedProfileDraft) {
  for (const file of draft.documents) {
    if (await session.files.read(file.path) !== file.text) throw new Error("Profile document verification failed");
  }
  for (const file of draft.artifacts) {
    await session.files.readReference(file.path);
    const record = await session.harness.snapshot(ProfileArtifact, file.path, context);
    if (!same(record, file)) throw new Error("Profile artifact verification failed");
  }
  for (const file of draft.payloads ?? []) {
    if (!session.files.immutableArtifacts) throw new Error("Payload archives require physical files");
    const record = await session.harness.snapshot(ProfileArtifact, file.path, context);
    if (!same(record, { ...file, binary: true, saved: false })) throw new Error("Profile payload metadata verification failed");
  }
}
async function verifyConversation(session: ProfileRuntime, source: NormalizedProfileDraft["conversations"][number], reference: ConversationReference) {
  const entries = await history(session, reference);
  if (entries.length !== source.entries.length) throw new Error("Conversation ledger count mismatch");
  for (const [ordinal, entry] of entries.entries()) {
    const expected = source.entries[ordinal]!;
    if (!same({ kind: entry.kind, model: entry.model, data: entry.data }, { kind: expected.kind, model: expected.model, data: expected.data })
        || entry.head !== (expected.head === "self" ? entry.id : undefined)) throw new Error("Conversation ledger verification failed");
  }
  const conversation = (await session.harness.conversation(reference.conversationID, context))!;
  const active = (await conversation.context(context)).messages;
  if (!same(active, source.expectedContext)) throw new Error(`Conversation active context mismatch: key=${source.key} stored=${active.length} expected=${source.expectedContext.length}`);
  const metadata = await session.conversations.metadata(reference);
  if (!same((await session.harness.snapshot(ConversationApplicationMetadata, reference.conversationID, context))?.fields, source.metadata ?? {})) throw new Error("Conversation application metadata mismatch");
  if (!same(metadata.agent?.model, source.agent.model ?? undefined)
      || (source.agent.thinkingLevel !== undefined && metadata.agent?.thinkingLevel !== source.agent.thinkingLevel)) throw new Error("Conversation model selection mismatch");
  if (metadata.presentation?.title !== source.title || metadata.favorite !== source.favorite || metadata.unread !== source.unread) throw new Error("Conversation presentation mismatch");
}
async function verifyRuntime(session: ProfileRuntime) {
  const inspection = await session.harness.inspect(context);
  if (inspection.scheduling !== "paused" || inspection.tasks.length || inspection.submissions.length) throw new Error("Profile installation must remain dormant");
  if (await session.files.integrity() !== "ok") throw new Error("Profile SQLite integrity failed");
}
export async function installOxProfile(draft: NormalizedProfileDraft, host: ProfileInstallHost) {
  let session: ProfileRuntime | undefined;
  try {
    const validateConversation = validate(draft);
    if (host.conversations && draft.conversations.length) throw new Error("Profile installation cannot mix inline and streamed conversations");
    for (const source of draft.conversations) validateConversation(source);
    if ((await host.database.all("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")).length) throw new Error("Profile installation requires a fresh staged database");
    session = await openProfileRuntime({ ...host, profileID: draft.profileID, models: createModels() });
    for (const file of draft.documents) await session.files.write(file.path, file.text);
    for (const file of draft.artifacts) {
      if (file.size > (file.binary ? 32 * 1024 * 1024 : 200 * 1024)) throw new Error("Profile artifact exceeds supported size");
      await host.artifacts.read(file);
      await host.artifacts.flush(file.path);
      await session.harness.commit(async tx => {
        Object.assign(await tx.doc(ProfileArtifact, file.path, null), file);
        (await tx.doc(ProfileIndex)).files[file.path] = { size: file.size, mtime: 0, binary: file.binary };
      }, context);
    }
    for (const file of draft.payloads ?? []) {
      if (!host.artifacts.verifyPayload) throw new Error("Profile installation requires a streaming payload verifier");
      await host.artifacts.verifyPayload(file);
      await host.artifacts.flush(file.path);
      await session.harness.commit(async tx => {
        Object.assign(await tx.doc(ProfileArtifact, file.path, null), file, { binary: true, saved: false });
      }, context);
    }
    await verifyFiles(session, draft);
    const conversations: { key: string; reference: ConversationReference }[] = [];
    for await (const source of host.conversations ?? draft.conversations) {
      if (host.conversations) validateConversation(source);
      const conversation = await session.harness.createConversation({ ownership: { kind: "ownerless" }, agent: source.agent,
        init: async (tx, id) => {
          (await tx.doc(ConversationApplicationMetadata, id)).fields = source.metadata ?? {};
          for (const entry of source.entries) await tx.appendEntry(id, entry);
        } }, context);
      const reference = session.conversations.reference(conversation.id);
      await session.conversations.present(reference, { title: source.title, favorite: source.favorite, visible: true });
      const newest = (await conversation.entries({}, 1, undefined, context)).items[0]?.id;
      if (!source.unread) await session.conversations.markRead(reference, newest ?? null);
      await verifyConversation(session, source, reference);
      conversations.push({ key: source.key, reference });
    }
    await verifyRuntime(session);
    return { conversations };
  } finally {
    if (session) await session.close();
    else { try { await host.database.close(); } finally { await host.artifacts.close(); } }
  }
}
