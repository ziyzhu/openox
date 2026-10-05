import { afterEach, beforeEach, expect, test } from "bun:test";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import { Harness, createRegistry, defineDoc, type EntryRecord, type ConversationId } from "@earendil-works/pi-durable";
import { fauxAssistantMessage } from "@earendil-works/pi-ai/providers/faux";
import { OxConversations, ConversationPresentation, ConversationFavorite, ConversationReadState, type ConversationHistoryCursor } from "../src/index";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { ChatBindings as Conversations, ConversationIdentity } from "../src/chat-bindings";
import { backend } from "./sqlite-backend";

const context = BACKGROUND_CONTEXT;
let harness: Harness;
let conversations: Conversations;
let storage: ReturnType<typeof backend>;
let presentation: OxConversations;
beforeEach(async () => {
  storage = backend();
  harness = await Harness.open(await SqliteStorage.open(storage.db), { registry: createRegistry(), models: createModels() }, context);
  conversations = new Conversations(harness); await conversations.restore();
  presentation = new OxConversations("profile-a", harness, () => {});
});
afterEach(async () => { await harness.close(context); });

test("concurrent attachment creates one Pi conversation, seeds once, and writes no shadow registry", async () => {
  const seed = [{ role: "user" as const, content: "seed", timestamp: 1 }];
  const [first, second] = await Promise.all([conversations.attach("chat-a", seed), conversations.attach("chat-a", seed)]);
  expect(first.id).toBe(second.id);
  expect((await first.entries({}, 100, undefined, context)).items.filter(entry => entry.kind === "pi.user")).toHaveLength(1);
  expect(await harness.snapshot(ConversationIdentity, first.id, context)).toEqual({ chatID: "chat-a" });
  const obsolete = defineDoc<{ byID: Record<string, number> }>({ kind: "ox.chats", version: 1, scope: "session", initial: () => ({ byID: {} }) });
  expect(await harness.snapshot(obsolete, context)).toBeUndefined();
  expect(conversations.list()).toEqual([{ chatID: "chat-a", id: first.id }]);
});

test("a discarded lookup is rebuilt from Pi records and per-conversation identity", async () => {
  const first = await conversations.attach("chat-a", []);
  const second = await conversations.attach("chat-b", []);
  await harness.createConversation({ ownership: { kind: "ownerless" } }, context);
  const restored = new Conversations(harness); await restored.restore();
  expect((await restored.forChat("chat-a")).id).toBe(first.id);
  expect((await restored.forChat("chat-b")).id).toBe(second.id);
  expect(restored.list()).toHaveLength(2); // An unbound Pi conversation does not become a fabricated Ox UUID.
  expect((await restored.attach("chat-a", [])).id).toBe(first.id);
  await expect(restored.forChat("missing")).rejects.toThrow("not attached");
});

test("duplicate external identities fail closed without replacing an existing lookup", async () => {
  const first = await conversations.attach("chat-a", []);
  await harness.createConversation({ ownership: { kind: "ownerless" }, init: async (tx, id) => {
    (await tx.doc(ConversationIdentity, id)).chatID = "chat-a";
  } }, context);
  await expect(conversations.restore()).rejects.toThrow("same Ox chat identity");
  expect((await conversations.forChat("chat-a")).id).toBe(first.id);
});

test("restoration follows Pi pagination rather than assuming a fixed conversation count", async () => {
  for (let index = 0; index < 101; index++) await harness.createConversation({ ownership: { kind: "ownerless" } }, context);
  const last = await conversations.attach("last-chat", []);
  const restored = new Conversations(harness); await restored.restore();
  expect((await restored.forChat("last-chat")).id).toBe(last.id);
  expect(restored.list()).toEqual([{ chatID: "last-chat", id: last.id }]);
}, 20_000);

test("visible listing is presentation-only, paginated, and never creates documents for internal roots", async () => {
  const internal = await harness.createConversation({ ownership: { kind: "ownerless" } }, context);
  const visible = await harness.createConversation({ ownership: { kind: "ownerless" }, agent: { model: { provider: "fixture", modelId: "mock" } } }, context);
  const reference = presentation.reference(visible.id);
  await presentation.present(reference, { title: "Visible", visible: true, favorite: true });
  const first = await presentation.list(1);
  expect(first.items).toHaveLength(0);
  const second = await presentation.list(1, first.next);
  expect(second.items.map(item => item.reference)).toEqual([reference]);
  expect(second.items[0]?.favorite).toBe(true);
  expect(second.items[0]?.agent?.model).toEqual({ provider: "fixture", modelId: "mock" });
  expect(await harness.snapshot(ConversationPresentation, internal.id, context)).toBeUndefined();
  expect(await harness.snapshot(ConversationReadState, internal.id, context)).toBeUndefined();
  await presentation.present(reference, { visible: false });
  expect((await presentation.list()).items).toHaveLength(0);
});

test("full paginated history preserves rich entries and nested fork cutoffs beyond active reset context", async () => {
  const parent = await harness.createConversation({ ownership: { kind: "ownerless" } }, context);
  const entries = await parent.commit(async tx => {
    const user = await tx.appendEntry(parent.id, { kind: "pi.user", model: [{ role: "user", content: "original", timestamp: 10 }],
      data: { attachments: [{ path: "artifacts/report.pdf", sha256: "retained" }], outcome: "sent" } });
    const assistant = await tx.appendEntry(parent.id, { kind: "pi.assistant", model: [fauxAssistantMessage([
      { type: "thinking", thinking: "reason", thinkingSignature: "opaque-signature" }, { type: "text", text: "reply" },
    ], { timestamp: 11 })] });
    await tx.appendEntry(parent.id, { kind: "pi.reset", head: "self" });
    await tx.appendEntry(parent.id, { kind: "pi.user", model: [{ role: "user", content: "new context", timestamp: 12 }] });
    return { user, assistant };
  }, context);
  expect((await parent.context(context)).entries.some(entry => entry.id === entries.user.id)).toBe(false);
  expect((await presentation.history(presentation.reference(parent.id))).items).toHaveLength(4);
  const fork = await parent.fork(entries.assistant.id, { ownership: { kind: "ownerless" } }, context);
  const forkEntry = await fork.commit(tx => tx.appendEntry(fork.id, { kind: "ox.rich", data: { blocks: [{ type: "diagnostic", text: "kept" }], timestamp: 13 } }), context);
  await fork.commit(tx => tx.appendEntry(fork.id, { kind: "ox.rich", data: { text: "excluded child tail" } }), context);
  const nested = await fork.fork(forkEntry.id, { ownership: { kind: "ownerless" } }, context);
  const result: EntryRecord[] = [];
  let cursor: ConversationHistoryCursor | undefined;
  do {
    const page = await presentation.history(presentation.reference(nested.id), 1, cursor);
    result.push(...page.items); cursor = page.next;
    if (result.length === 1) await nested.commit(tx => tx.appendEntry(nested.id, { kind: "ox.rich", data: { text: "newer commit" } }), context);
  } while (cursor);
  expect(result.map(entry => entry.id)).toEqual([forkEntry.id, entries.assistant.id, entries.user.id]);
  expect(result[1]).toEqual(entries.assistant);
  expect(result[2]).toEqual(entries.user);
  expect(new Set(result.map(entry => entry.id)).size).toBe(result.length);
  await expect(presentation.history(presentation.reference(parent.id), 101)).rejects.toThrow("Page size");
});

test("history reads the entire ledger across more than one hundred entries", async () => {
  const handle = await harness.createConversation({ ownership: { kind: "ownerless" } }, context);
  await handle.commit(async tx => {
    for (let index = 0; index < 105; index++) await tx.appendEntry(handle.id, { kind: "ox.rich", data: { index } });
  }, context);
  const first = await presentation.history(presentation.reference(handle.id));
  expect(first.items).toHaveLength(100);
  const second = await presentation.history(presentation.reference(handle.id), 100, first.next);
  expect(second.items).toHaveLength(5); expect(second.next).toBeUndefined();
  expect([...first.items, ...second.items].map(entry => entry.data)).toEqual(Array.from({ length: 105 }, (_, index) => ({ index: 104 - index })));
});

test("fork presentation inherits current title/visibility but resets favorite and read-state", async () => {
  const parent = await harness.createConversation({ ownership: { kind: "ownerless" } }, context);
  const reference = presentation.reference(parent.id);
  await presentation.present(reference, { title: "Then", visible: true, favorite: true });
  const entry = await parent.commit(tx => tx.appendEntry(parent.id, { kind: "pi.user", model: [{ role: "user", content: "hello", timestamp: 1 }] }), context);
  await presentation.markRead(reference, entry.id);
  expect((await presentation.metadata(reference)).unread).toBe(false);
  await presentation.present(reference, { title: "Now" });
  const fork = await parent.fork(entry.id, { ownership: { kind: "ownerless" } }, context);
  const metadata = await presentation.metadata(presentation.reference(fork.id));
  expect(metadata.presentation).toEqual({ title: "Now", visible: true });
  expect(metadata.favorite).toBe(false);
  expect(metadata.readState.lastReadEntryID).toBeNull();
  expect(metadata.unread).toBe(true);
  const hidden = await harness.createConversation({ ownership: { kind: "ownerless" } }, context);
  const foreign = await hidden.commit(tx => tx.appendEntry(hidden.id, { kind: "pi.user" }), context);
  await expect(presentation.markRead(reference, foreign.id)).rejects.toThrow("not visible");
  expect(await harness.snapshot(ConversationFavorite, parent.id, context)).toEqual({ favorite: true });
});

test("Profile and continuation cursor mismatches reject before Pi lookup, including absent IDs", async () => {
  const handle = await harness.createConversation({ ownership: { kind: "ownerless" } }, context);
  const reference = presentation.reference(handle.id);
  const wrong = { profileID: "other", conversationID: 999999 as ConversationId };
  await expect(presentation.metadata(wrong)).rejects.toThrow("Profile mismatch");
  await expect(presentation.present(wrong)).rejects.toThrow("Profile mismatch");
  await expect(presentation.markRead(wrong, null)).rejects.toThrow("Profile mismatch");
  await expect(presentation.history(wrong)).rejects.toThrow("Profile mismatch");
  await expect(presentation.list(1, { profileID: "other", pi: {} })).rejects.toThrow("Profile mismatch");
  await expect(presentation.history(reference, 1, { ...wrong, pi: {} })).rejects.toThrow("cursor scope mismatch");
  await expect(presentation.history(reference, 1, { ...reference, conversationID: 999999 as ConversationId, pi: {} })).rejects.toThrow("cursor scope mismatch");
});

test("latest presentation documents checkpoint long real SQLite delta tails", async () => {
  const handle = await harness.createConversation({ ownership: { kind: "ownerless" } }, context);
  const reference = presentation.reference(handle.id);
  const entry = await handle.commit(tx => tx.appendEntry(handle.id, { kind: "pi.user" }), context);
  for (let index = 0; index < 70; index++) {
    await presentation.present(reference, { title: `Title ${index}`, visible: true, favorite: index % 2 === 0 });
    await presentation.markRead(reference, index % 2 === 0 ? entry.id : null);
  }
  const revisions = storage.connection.query<{ kind: string; bases: number; deltas: number }, []>(`SELECT json_extract(d.record, '$.kind') AS kind,
    sum(r.kind = 'base') AS bases, sum(r.kind = 'delta') AS deltas FROM documents d
    JOIN document_revisions r ON r.document_id = d.id WHERE json_extract(d.record, '$.kind') LIKE 'ox.conversation.%' GROUP BY d.kind`).all();
  expect(revisions).toHaveLength(3);
  for (const revision of revisions) { expect(revision.bases).toBe(1); expect(revision.deltas).toBeLessThanOrEqual(31); }
  expect((await presentation.metadata(reference)).presentation?.title).toBe("Title 69");
}, 20_000);
