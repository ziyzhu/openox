import { afterEach, expect, test } from "bun:test";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import { fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai/providers/faux";
import { createRegistry, defineExtension, defineTool, type ConversationId, type AgentState, type EntryRecord } from "@earendil-works/pi-durable";
import { Type } from "typebox";
import { rm } from "node:fs/promises";
import { ChatBindings, ConversationIdentity } from "../src/chat-bindings";
import { openOxAgentSession, type OxAgentSession, type CommittedEvent, type SessionOptions,
  type ConversationReference, type ConversationHistoryCursor, type ConversationListCursor } from "../src/index";
import { IOSAgentAdapter } from "../src/adapters/ios/agent";
import { deliver, streamEvent } from "../src/adapters/ios/bridge";
import { composeIOSPrompt } from "../src/adapters/ios/prompts";
import { backend } from "./sqlite-backend";

const context = BACKGROUND_CONTEXT;
const sessions: OxAgentSession[] = [];
afterEach(async () => { await Promise.all(sessions.splice(0).map(session => session.close())); });

async function fixture(profileID = "fixture", onEvents: (id: ConversationId, events: CommittedEvent[]) => Promise<void> = async () => {}, overrides: Partial<SessionOptions> = {}) {
  const models = createModels();
  const faux = fauxProvider({ provider: "fixture", models: [{ id: "mock" }], tokensPerSecond: 100_000 });
  faux.setResponses(Array.from({ length: 4 }, () => fauxAssistantMessage([{ type: "text", text: "hello" }])));
  models.setProvider(faux.provider);
  const session = await openOxAgentSession({ database: backend().db, profileID, models, registry: createRegistry(),
    createBlobID: async () => crypto.randomUUID(), authorizeFile: async () => {}, onEvents,
    settings: { retry: { enabled: false }, compaction: { enabled: false } }, ...overrides });
  sessions.push(session);
  return session;
}
async function conversation(session: OxAgentSession) {
  return session.harness.createConversation({ ownership: { kind: "ownerless" }, agent: { model: { provider: "fixture", modelId: "mock" } } }, context);
}

test("core entry does not install host globals or runtime shims", async () => {
  const script = `const before = [console, URL, structuredClone, AbortController, setTimeout];
    await import('./packages/agent/src/index.ts');
    if (before.some((value, index) => value !== [console, URL, structuredClone, AbortController, setTimeout][index])) throw Error('Global side effect');
    if (typeof __oxDurableRequest !== 'undefined') throw Error('Native global');`;
  const child = Bun.spawn(["bun", "-e", script], { cwd: new URL("../../../", import.meta.url).pathname, stderr: "pipe", stdout: "pipe" });
  const [code, error] = await Promise.all([child.exited, new Response(child.stderr).text()]);
  expect(code, error).toBe(0);
});

test("in-process host executes an unbound Pi conversation and delivers committed events", async () => {
  const events: CommittedEvent[] = [];
  const session = await fixture("fixture", async (_, frames) => { events.push(...frames); });
  const chat = await conversation(session);
  const result = await session.run(chat.id, { type: "input", content: "hello", requestId: "one" });
  expect(result.receipt.status).toBe("done");
  expect(result.messages.at(-1)?.role).toBe("assistant");
  expect(events.some(event => event.type === "run_end")).toBe(true);
});

test("Sessions with colliding numeric conversation IDs isolate models, files, observers and close", async () => {
  const firstEvents: ConversationId[] = []; const secondEvents: ConversationId[] = [];
  const first = await fixture("first", async id => { firstEvents.push(id); });
  const second = await fixture("second", async id => { secondEvents.push(id); });
  const a = await conversation(first); const b = await conversation(second);
  expect(a.id).toBe(b.id);
  await Promise.all([first.files.write("MEMORY.md", "first"), second.files.write("MEMORY.md", "second")]);
  await Promise.all([first.run(a.id, { type: "input", content: "a" }), second.run(b.id, { type: "input", content: "b" })]);
  expect(firstEvents.length).toBeGreaterThan(0); expect(secondEvents.length).toBeGreaterThan(0);
  await first.close();
  await expect(first.run(a.id, { type: "input", content: "closed" })).rejects.toThrow("closed");
  expect(await second.files.read("MEMORY.md")).toBe("second");
  await second.files.write("SOUL.md", "still open");
  expect(await second.files.read("SOUL.md")).toBe("still open");
});

test("completed request IDs deduplicate without waiting for a nonexistent second run_end", async () => {
  const session = await fixture(); const chat = await conversation(session);
  const input = { type: "input" as const, content: "hello", requestId: "same" };
  const first = await session.run(chat.id, input);
  const again = await session.run(chat.id, input);
  expect(again.receipt.id).toBe(first.receipt.id);
});

test("concurrent observer attachment creates one committed delivery stream", async () => {
  const events: CommittedEvent[] = [];
  const session = await fixture("fixture", async (_, frames) => { events.push(...frames); });
  const handle = await conversation(session);
  await Promise.all([session.observe(handle.id), session.observe(handle.id)]);
  await session.run(handle.id, { type: "input", content: "hello" });
  expect(events.filter(event => event.type === "run_end")).toHaveLength(1);
});

test("multiple conversations in one Session route events by Pi identity", async () => {
  const ids = new Set<ConversationId>();
  const session = await fixture("fixture", async id => { ids.add(id); });
  const a = await conversation(session); const b = await conversation(session);
  const results = await Promise.all([session.run(a.id, { type: "input", content: "a" }), session.run(b.id, { type: "input", content: "b" })]);
  expect(results.map(result => result.receipt.status)).toEqual(["done", "done"]);
  expect(ids).toEqual(new Set([a.id, b.id]));
});

test("identical external chat UUIDs bind independently without changing persisted fields", async () => {
  const first = await fixture("first"); const second = await fixture("second");
  const a = new ChatBindings(first.harness); const b = new ChatBindings(second.harness);
  const firstHandle = await a.attach("same-external-uuid", []); const secondHandle = await b.attach("same-external-uuid", []);
  expect(await first.harness.snapshot(ConversationIdentity, firstHandle.id, context)).toEqual({ chatID: "same-external-uuid" });
  expect(await second.harness.snapshot(ConversationIdentity, secondHandle.id, context)).toEqual({ chatID: "same-external-uuid" });
  await first.close();
  expect((await b.forChat("same-external-uuid")).id).toBe(secondHandle.id);
});

test("file tools request host authorization before mutating Profile documents", async () => {
  const faux = fauxProvider({ provider: "fixture", models: [{ id: "mock" }], tokensPerSecond: 100_000 });
  faux.setResponses([fauxAssistantMessage([{ type: "toolCall", id: "write", name: "write", arguments: { path: "MEMORY.md", content: "forbidden" } }], { stopReason: "toolUse" }),
    fauxAssistantMessage([{ type: "text", text: "Denied" }])]);
  const models = createModels(); models.setProvider(faux.provider);
  const authorized: ConversationId[] = [];
  const session = await fixture("fixture", undefined, { models, authorizeFile: async id => { authorized.push(id); throw new Error("Permission denied"); } });
  const handle = await conversation(session);
  const result = await session.run(handle.id, { type: "input", content: "write" });
  expect(authorized).toEqual([handle.id]);
  expect(result.messages.some(message => message.role === "toolResult" && message.isError)).toBe(true);
  await expect(session.files.read("MEMORY.md")).rejects.toThrow("not found");
});

async function holdingSession(database: SessionOptions["database"]) {
  let started!: () => void;
  const running = new Promise<void>(resolve => { started = resolve; });
  const registry = createRegistry();
  registry.install(defineExtension({ name: "holding", tools: [defineTool({ name: "hold", description: "Wait for cancellation", parameters: Type.Object({}), replay: "unsafe",
    execute: async (_, api, context) => {
      started();
      await new Promise<void>((_, reject) => { context.abortSignal!.addEventListener("abort", () => reject(context.abortSignal!.reason), { once: true }); });
      return {};
    } })] }));
  const models = createModels();
  const faux = fauxProvider({ provider: "fixture", models: [{ id: "mock" }], tokensPerSecond: 100_000 });
  faux.setResponses([fauxAssistantMessage([{ type: "toolCall", id: "hold", name: "hold", arguments: {} }], { stopReason: "toolUse" })]);
  models.setProvider(faux.provider);
  return { session: await fixture("holding", undefined, { database, models, registry }), running };
}

test("explicit abort propagates to injected tools and settles only the selected conversation", async () => {
  const { session, running } = await holdingSession(backend().db);
  const handle = await conversation(session);
  const result = session.run(handle.id, { type: "input", content: "hold" });
  await running;
  await session.abort(handle.id);
  expect((await result).receipt.status).toBe("unanswered");
  expect((await session.harness.inspect(context)).tasks).toHaveLength(0);
});

test("close/reopen preserves checkpoints without cancellation and rejects old runtime operations", async () => {
  const path = `/tmp/ox-agent-session-${crypto.randomUUID()}.sqlite`;
  try {
    const { session, running } = await holdingSession(backend(path).db);
    const handle = await conversation(session);
    const result = session.run(handle.id, { type: "input", content: "hold", requestId: "interrupted" }).catch(error => error);
    await running;
    await session.close();
    expect(await result).toBeInstanceOf(Error);
    await expect(session.abort(handle.id)).rejects.toThrow("closed");
    const reopened = await fixture("holding", undefined, { database: backend(path).db });
    const inspection = await reopened.harness.inspect(context);
    expect(inspection.scheduling).toBe("paused");
    expect(inspection.tasks.length).toBeGreaterThan(0);
    expect(inspection.tasks.every(task => !task.record.abortRequested)).toBe(true);
    expect((await reopened.harness.conversation(handle.id, context))?.id).toBe(handle.id);
    await reopened.abort(handle.id);
    await reopened.close();
  } finally { for (const suffix of ["", "-wal", "-shm"]) await rm(path + suffix, { force: true }); }
});

test("qualified references isolate colliding Profile IDs before run/observe/abort/inspect lookup", async () => {
  const first = await fixture("first"); const second = await fixture("second");
  const a = await conversation(first); const b = await conversation(second);
  expect(a.id).toBe(b.id);
  const aRef = first.conversations.reference(a.id); const bRef = second.conversations.reference(b.id);
  await first.conversations.present(aRef, { title: "First", visible: true });
  await second.conversations.present(bRef, { title: "Second", visible: true });
  for (const operation of [() => first.run(bRef, { type: "input", content: "wrong" }), () => first.observe(bRef),
    () => first.abort(bRef), () => first.inspect(bRef), () => first.conversations.history(bRef)]) {
    await expect(operation()).rejects.toThrow("Profile mismatch");
  }
  expect((await first.conversations.history(aRef)).items).toHaveLength(0);
  await Promise.all([first.run(aRef, { type: "input", content: "a" }), second.run(bRef, { type: "input", content: "b" })]);
  expect((await first.conversations.metadata(aRef)).presentation?.title).toBe("First");
  expect((await second.conversations.metadata(bRef)).presentation?.title).toBe("Second");
  await first.close();
  await expect(first.conversations.metadata(bRef)).rejects.toThrow("Profile mismatch");
  await expect(first.conversations.metadata(aRef)).rejects.toThrow("closed");
});

function value<T>(result: { ok: true; value: T } | { ok: false; error: unknown }): T {
  if (!result.ok) throw result.error;
  return result.value;
}

test("Session ExecutionEnv exposes only visible, read-only Pi metadata and full-history pages", async () => {
  const session = await fixture();
  const visible = await conversation(session); const internal = await conversation(session);
  const reference = session.conversations.reference(visible.id);
  await session.conversations.present(reference, { title: "Virtual", visible: true });
  const original = await visible.commit(tx => tx.appendEntry(visible.id, { kind: "pi.user", model: [{ role: "user", content: "old scrollback", timestamp: 1 }] }), context);
  await visible.commit(tx => tx.appendEntry(visible.id, { kind: "pi.reset", head: "self" }), context);
  expect(value(await session.env.listDir("/chats", context)).map(info => info.name)).toEqual([String(visible.id)]);
  expect(value(await session.env.listDir(`/conversations/${visible.id}`, context)).map(info => info.name)).toEqual(["metadata", "history"]);
  const metadata = JSON.parse(value(await session.env.readTextFile(`/conversations/${visible.id}/metadata`, context)));
  expect(metadata.reference).toEqual(reference); expect(metadata.presentation.title).toBe("Virtual");
  const history = JSON.parse(value(await session.env.readTextFile(`/conversations/${visible.id}/history`, context)));
  expect(history.order).toBe("newest-first");
  expect(history.items.some((entry: { id: number }) => entry.id === original.id)).toBe(true);
  expect((await visible.context(context)).entries.some(entry => entry.id === original.id)).toBe(false);
  expect(value(await session.env.exists(`/conversations/${internal.id}`, context))).toBe(false);
  expect(value(await session.env.exists(`/conversations/0${visible.id}`, context))).toBe(false);
  const path = `/conversations/${visible.id}/history`;
  for (const result of [await session.env.writeFile(path, "override", context), await session.env.remove(path, undefined, context),
    await session.env.createDir(`/conversations/${visible.id}`, undefined, context), await session.env.flushFile(path, context)]) {
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.error.code).toBe("permission_denied");
  }
  expect(await session.files.index()).toEqual({});
  // Use Pi's real model/tool loop, not merely a direct filesystem call.
  const faux = fauxProvider({ provider: "fixture", models: [{ id: "mock" }], tokensPerSecond: 100_000 });
  faux.setResponses([fauxAssistantMessage([{ type: "toolCall", id: "history", name: "read", arguments: { path } }], { stopReason: "toolUse" }),
    fauxAssistantMessage([{ type: "text", text: "read history" }])]);
  const models = createModels(); models.setProvider(faux.provider);
  const readerSession = await fixture("reader", undefined, { models });
  const reader = await conversation(readerSession);
  const readerRef = readerSession.conversations.reference(reader.id);
  await readerSession.conversations.present(readerRef);
  await reader.commit(tx => tx.appendEntry(reader.id, { kind: "pi.user", model: [{ role: "user", content: "readable old history", timestamp: 1 }] }), context);
  const result = await readerSession.run(readerRef, { type: "input", content: "Read the virtual history" });
  const tool = result.messages.find(message => message.role === "toolResult");
  expect(tool?.role === "toolResult" && !tool.isError).toBe(true);
  expect(JSON.stringify(tool)).toContain("readable old history");
});

test("presentation and history reopen from SQLite without creating another chat authority", async () => {
  const path = `/tmp/ox-agent-presentation-${crypto.randomUUID()}.sqlite`;
  try {
    const first = await fixture("reopen", undefined, { database: backend(path).db });
    const handle = await conversation(first); const reference = first.conversations.reference(handle.id);
    await first.conversations.present(reference, { title: "Retained", visible: true, favorite: true });
    await first.run(reference, { type: "input", content: "history", requestId: "retained" });
    const before = await first.conversations.history(reference);
    await first.conversations.markRead(reference, before.items[0]!.id);
    await first.close();
    const reopened = await fixture("reopen", undefined, { database: backend(path).db });
    expect((await reopened.conversations.history(reference)).items).toEqual(before.items);
    const metadata = (await reopened.conversations.list()).items[0]!;
    expect(metadata.reference).toEqual(reference);
    expect(metadata.presentation?.title).toBe("Retained");
    expect(metadata.favorite).toBe(true); expect(metadata.unread).toBe(false);
    expect(value(await reopened.env.exists(`/conversations/${handle.id}/history`, context))).toBe(true);
    expect((await reopened.harness.inspect(context)).scheduling).toBe("paused");
    await reopened.close();
  } finally { for (const suffix of ["", "-wal", "-shm"]) await rm(path + suffix, { force: true }); }
});

test("bounded iOS commands route qualified references and execute structured prompts through the native boundary", async () => {
  const path = `/tmp/ox-ios-prompts-${crypto.randomUUID()}.sqlite`;
  let storage = backend(path);
  const modelRequests: { systemPrompt: string; messages: { role: string; content: unknown }[] }[] = [];
  const host = globalThis as typeof globalThis & { __oxDurableRequest?: (id: number, json: string) => void };
  const previous = host.__oxDurableRequest;
  let adapter = new IOSAgentAdapter();
  host.__oxDurableRequest = (id, json) => {
    const request = JSON.parse(json);
    void (async () => {
      if (request.method === "sql") return storage.request(request.params.op, request.params.sql, request.params.params);
      if (request.method === "uuid") return crypto.randomUUID();
      if (request.method === "report" || request.method === "agentEvents") return {};
      if (request.method === "nativeModel") {
        modelRequests.push(request.params);
        streamEvent(id, JSON.stringify({ type: "done", reason: "stop", message: {
          ...fauxAssistantMessage([{ type: "text", text: "native reply" }]), api: "ox-native", model: "mock", timestamp: Date.now(),
        } }));
        return null;
      }
      throw new Error(`Unexpected native capability: ${request.method}`);
    })().then(result => deliver(id, JSON.stringify(result), null), error => deliver(id, "null", String(error)));
  };
  try {
    await adapter.command({ action: "open", profileID: "ios-profile" });
    const scope = { hostID: "ios-host", profileID: "ios-profile" };
    const hostContext = { active: scope, hosts: [{ ...scope, functions: ["ox"], serviceKinds: ["web", "ios", "mcp"] as ("web" | "ios" | "mcp")[], presentation: "chat-bubbles" as const, externalFiles: true }] };
    const config = { chatID: "external-uuid", title: "Native", promptState: { soul: "## Voice\nBe helpful.", memory: "frozen memory", hostContext }, model: "mock", contextWindow: 100000,
      maxTokens: 1000, reasoning: false, tools: [], messages: [{ role: "user" as const, content: "seed", timestamp: 1 }] };
    const attached = await adapter.command({ action: "attach", config }) as { conversationID: ConversationId; reference: ConversationReference };
    expect(attached.reference).toEqual({ profileID: "ios-profile", conversationID: attached.conversationID });
    const metadata = await adapter.command({ action: "conversationMetadata", reference: attached.reference }) as { agent: AgentState; presentation: { title: string } };
    expect(metadata.agent.model?.provider).toBe("ox-native:external-uuid");
    expect(metadata.agent.extensions).toContain("ox-chat:external-uuid");
    expect(metadata.presentation.title).toBe("Native");
    const history = await adapter.command({ action: "conversationHistory", reference: attached.reference, limit: 1 }) as { items: unknown[]; next?: ConversationHistoryCursor };
    expect(JSON.stringify(history.items)).toContain("seed");
    await adapter.command({ action: "conversationPresent", chatID: config.chatID, presentation: { favorite: true, title: "Updated" } });
    const again = await adapter.command({ action: "attach", config, reference: attached.reference }) as typeof attached;
    expect(again.reference).toEqual(attached.reference);
    const list = await adapter.command({ action: "conversationList" }) as { items: { favorite: boolean; presentation: { title: string } }[] };
    expect(list.items).toHaveLength(1); expect(list.items[0]!.favorite).toBe(true); expect(list.items[0]!.presentation.title).toBe("Updated");
    await expect(adapter.command({ action: "conversationHistory", chatID: "missing", reference: { ...attached.reference, profileID: "wrong" } })).rejects.toThrow("Profile mismatch");
    await expect(adapter.command({ action: "inspect", profileID: "wrong", chatID: "missing" })).rejects.toThrow("Profile mismatch");
    const inspected = await adapter.command({ action: "inspect", chatID: config.chatID }) as { conversations: { chatID: string; id: ConversationId }[] };
    expect(inspected.conversations).toEqual([{ chatID: config.chatID, id: attached.conversationID }]);
    const second = await adapter.command({ action: "attach", config: { ...config, chatID: "second-uuid" } }) as typeof attached;
    await expect(adapter.command({ action: "attach", config, reference: second.reference })).rejects.toThrow("UUID/reference mismatch");
    await expect(adapter.command({ action: "conversationMetadata", chatID: config.chatID, reference: second.reference })).rejects.toThrow("UUID/reference mismatch");
    const prompt = composeIOSPrompt(config.promptState);
    expect(await adapter.command({ action: "composePrompt", promptState: config.promptState })).toEqual(prompt);
    const turnState = { skills: [{ name: "example", description: "Example skill" }], skillConflicts: [],
      attachedServices: [{ domain: "ios:files", signIn: "authorized" as const, fileMounts: ["files/a"] }],
      artifactPaths: ["artifacts/note.md"], storageMode: "temporary" as const, responseLanguage: { identifier: "zh-Hans", name: "Chinese (Simplified)" }, hostContext };
    const foreignScope = { ...scope, hostID: "another-host" };
    await expect(adapter.command({ action: "run", reference: attached.reference, content: "wrong owner", turnState: { ...turnState,
      hostContext: { active: foreignScope, hosts: [{ ...hostContext.hosts[0]!, ...foreignScope }] } } })).rejects.toThrow("attached host/Profile scope");
    expect(modelRequests).toHaveLength(0);
    const run = await adapter.command({ action: "run", reference: attached.reference, content: "first", turnState }) as { receipt: { status: string } };
    expect(run.receipt.status).toBe("done");
    expect(modelRequests[0]!.systemPrompt.startsWith(prompt.rendered)).toBe(true);
    expect(modelRequests[0]!.systemPrompt).toContain("<profile_files>");
    expect(modelRequests[0]!.systemPrompt).not.toContain("<ox>");
    expect(modelRequests[0]!.messages.every(message => message.role !== "system")).toBe(true);
    expect(JSON.stringify(modelRequests[0]!.messages.at(-1))).toContain("<turn-state>");
    expect(JSON.stringify(modelRequests[0]!.messages.at(-1))).toContain("files/a");
    expect(JSON.stringify(modelRequests[0]!.messages.at(-1))).toContain("Active host/Profile:");
    expect(JSON.stringify(modelRequests[0]!.messages.at(-1))).toContain("ios-host");
    expect(JSON.stringify(modelRequests[0]!.messages.at(-1))).toContain("This is a temporary conversation");
    const updated = { ...config, promptState: { ...config.promptState, soul: "## Voice\nBe direct." } };
    await adapter.command({ action: "fileWrite", path: "MEMORY.md", text: "new live memory" });
    await adapter.command({ action: "attach", config: updated, reference: attached.reference });
    await adapter.command({ action: "run", reference: attached.reference, content: "second",
      turnState: { ...turnState, skills: [], attachedServices: [], artifactPaths: [], storageMode: "persisted", responseLanguage: null } });
    expect(modelRequests[1]!.systemPrompt).toContain("Be direct.");
    expect(modelRequests[1]!.systemPrompt).not.toContain("Be helpful.");
    expect(modelRequests[1]!.systemPrompt).toContain("frozen memory");
    expect(modelRequests[1]!.systemPrompt).not.toContain("new live memory");
    expect(JSON.stringify(modelRequests[1]!.messages.at(-1))).not.toContain("files/a");
    const isolated = await adapter.command({ action: "attach", config: { ...config, chatID: "isolated", isolatedWorkspace: true } }) as typeof attached;
    await adapter.command({ action: "run", reference: isolated.reference, content: "workspace" });
    expect(modelRequests[2]!.systemPrompt).toContain("<durable_test_workspace>");
    const retained = await adapter.command({ action: "conversationHistory", reference: attached.reference, limit: 100 });
    await adapter.command({ action: "close" });
    storage = backend(path);
    adapter = new IOSAgentAdapter();
    await adapter.command({ action: "open", profileID: "ios-profile" });
    expect(await adapter.command({ action: "conversationHistory", reference: attached.reference, limit: 100 })).toEqual(retained);
    for (const [config_, reference_] of [[updated, attached.reference], [{ ...config, chatID: "second-uuid" }, second.reference],
      [{ ...config, chatID: "isolated", isolatedWorkspace: true }, isolated.reference]] as const) {
      await adapter.command({ action: "attach", config: config_, reference: reference_ });
    }
    await adapter.command({ action: "run", reference: attached.reference, content: "after reopen" });
    expect(modelRequests[3]!.systemPrompt).toBe(modelRequests[1]!.systemPrompt);
  } finally {
    try { await adapter.command({ action: "close" }); }
    finally {
      if (previous) host.__oxDurableRequest = previous; else delete host.__oxDurableRequest;
      for (const suffix of ["", "-wal", "-shm"]) await rm(path + suffix, { force: true });
    }
  }
});

test("failed initialization closes storage and rejects before exposing a Session", async () => {
  const db = backend().db;
  await expect(openOxAgentSession({ database: db, profileID: "", models: createModels(), registry: createRegistry(),
    createBlobID: async () => crypto.randomUUID(), authorizeFile: async () => {} })).rejects.toThrow("identity");
  await expect(db.get("SELECT 1")).rejects.toThrow("closed");
});

test("iOS startup lists summaries without loading long histories and opens them on demand after restart", async () => {
  const path = `/tmp/ox-ios-summaries-${crypto.randomUUID()}.sqlite`;
  let storage = backend(path);
  let entryRows = 0;
  const host = globalThis as typeof globalThis & { __oxDurableRequest?: (id: number, json: string) => void };
  const previous = host.__oxDurableRequest;
  let adapter = new IOSAgentAdapter();
  host.__oxDurableRequest = (id, json) => {
    const request = JSON.parse(json);
    void (async () => {
      if (request.method === "sql") {
        const result = await storage.request(request.params.op, request.params.sql, request.params.params);
        if (/SELECT.*FROM entries/s.test(request.params.sql)) entryRows += Array.isArray(result) ? result.length : result ? 1 : 0;
        return result;
      }
      if (request.method === "uuid") return crypto.randomUUID();
      if (request.method === "report" || request.method === "agentEvents") return {};
      throw new Error(`Unexpected native capability: ${request.method}`);
    })().then(result => deliver(id, JSON.stringify(result), null), error => deliver(id, "null", String(error)));
  };
  try {
    await adapter.command({ action: "open", profileID: "summary-profile" });
    const entries = [...Array.from({ length: 120 }, (_, index) => ({ kind: "pi.user",
      model: [{ role: "user" as const, content: `history-${index}-${"x".repeat(1024)}`, timestamp: index + 1 }] })),
      { kind: "pi.reset", head: "self" as const }, { kind: "ox.native.presentation", data: {} }];
    const metadata = { createdAt: 123, lastActivity: 456, preview: "Retained preview", nativeProviderID: "fixture" };
    const saved = await adapter.command({ action: "conversationCreate", title: "Retained", favorite: true, unread: false,
      metadata, agent: { model: { provider: "fixture", modelId: "mock" } }, entries }) as { reference: ConversationReference };
    await adapter.command({ action: "conversationCreate" });
    entryRows = 0;
    const full = await adapter.command({ action: "applicationLoad", reference: saved.reference }) as { entries: EntryRecord[] };
    expect(full.entries).toHaveLength(122);
    expect(entryRows).toBeGreaterThanOrEqual(120);
    const fork = await adapter.command({ action: "conversationFork", reference: saved.reference,
      entryID: full.entries[50]!.id, title: "Fork" }) as typeof saved;
    const hidden = await adapter.command({ action: "conversationCreate", entries }) as typeof saved;
    await adapter.command({ action: "applicationDelete", reference: hidden.reference });
    await adapter.command({ action: "close" });
    storage = backend(path);
    adapter = new IOSAgentAdapter();
    await adapter.command({ action: "open", profileID: "summary-profile" });
    entryRows = 0;
    type Summary = { reference: ConversationReference; metadata: typeof metadata; hasTranscript: boolean;
      presentation: { title: string }; favorite: boolean; unread: boolean; agent: { model: { modelId: string } } };
    const summaries: Summary[] = [];
    let cursor: ConversationListCursor | undefined;
    do {
      const page = await adapter.command({ action: "applicationList", limit: 1, listCursor: cursor }) as { items: Summary[]; next?: ConversationListCursor };
      summaries.push(...page.items); cursor = page.next;
    } while (cursor);
    const summary = summaries.find(item => item.reference.conversationID === saved.reference.conversationID)!;
    expect(summary.metadata).toEqual(metadata);
    expect(summary.presentation.title).toBe("Retained");
    expect(summary.favorite).toBe(true);
    expect(summary.unread).toBe(false);
    expect(summary.agent.model.modelId).toBe("mock");
    expect(summaries.filter(item => item.hasTranscript).map(item => item.reference)).toEqual([saved.reference, fork.reference]);
    expect(summaries.some(item => item.reference.conversationID === hidden.reference.conversationID)).toBe(false);
    expect(JSON.stringify(summaries)).not.toContain("history-");
    expect(entryRows).toBeLessThan(20);
    const reopened = await adapter.command({ action: "applicationLoad", reference: saved.reference }) as { entries: unknown[] };
    expect(reopened.entries).toEqual(full.entries);
    await expect(adapter.command({ action: "applicationList", listCursor: { profileID: "wrong", pi: {} } })).rejects.toThrow("Profile mismatch");
  } finally {
    await adapter.command({ action: "close" });
    host.__oxDurableRequest = previous;
    for (const suffix of ["", "-wal", "-shm"]) await rm(path + suffix, { force: true });
  }
}, 20_000);
