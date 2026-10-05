import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Message } from "@earendil-works/pi-ai";
import { defineDoc, type ConversationId, type Cursor, type Harness } from "@earendil-works/pi-durable";

/** Ox's external UUID only. Pi's conversation record owns identity, ancestry, ownership and execution. */
export const ConversationIdentity = defineDoc<{ chatID: string }>({
  kind: "ox.chat", version: 1, scope: "conversation", history: "latest", fork: "initial", initial: () => ({ chatID: "" }),
});
const context = BACKGROUND_CONTEXT;

/** Disposable lookup derived from Pi conversations, never a second persisted conversation registry. */
export class ChatBindings {
  private readonly ids = new Map<string, ConversationId>();
  private tail: Promise<unknown> = Promise.resolve();
  constructor(private readonly harness: Harness) {}

  async restore() {
    const records = await this.harness.commit(async tx => {
      const records = [];
      let cursor: Cursor | undefined;
      do {
        const page = await tx.scanConversations({}, 100, cursor);
        records.push(...page.items); cursor = page.next;
      } while (cursor);
      return records;
    }, context);
    const ids = new Map<string, ConversationId>();
    for (const record of records) {
      const identity = await this.harness.snapshot(ConversationIdentity, record.id, context);
      if (!identity?.chatID) continue; // Unbound roots/subagents/forks are still Pi conversations, not Ox UUID aliases.
      if (ids.has(identity.chatID)) throw new Error("Multiple Pi conversations have the same Ox chat identity");
      ids.set(identity.chatID, record.id);
    }
    this.ids.clear(); for (const [chatID, id] of ids) this.ids.set(chatID, id);
  }

  async forChat(chatID: string) {
    const id = this.ids.get(chatID);
    const conversation = id === undefined ? undefined : await this.harness.conversation(id, context);
    if (!conversation) throw new Error("Conversation not attached");
    return conversation;
  }

  async attach(chatID: string, seed: readonly Message[]) {
    if (!chatID) throw new Error("An external chat identity is required");
    const operation = this.tail.then(async () => {
      if (this.ids.has(chatID)) return this.forChat(chatID);
      const conversation = await this.harness.createConversation({ ownership: { kind: "ownerless" }, init: async (tx, id) => {
        (await tx.doc(ConversationIdentity, id)).chatID = chatID;
        for (const message of seed) await tx.appendEntry(id, { kind: `pi.${message.role === "toolResult" ? "tool-result" : message.role}`, model: [message] });
      } }, context);
      this.ids.set(chatID, conversation.id);
      return conversation;
    });
    this.tail = operation.catch(() => {});
    return operation;
  }

  chatID(id: ConversationId) { return [...this.ids].find(([, value]) => value === id)?.[0]; }
  list() { return [...this.ids].map(([chatID, id]) => ({ id, chatID })); }
}
