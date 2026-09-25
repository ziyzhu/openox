import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const source = readFileSync(
  "apps/ios/Ox/Host/Agent/LLM/Providers/KimiWebsiteProvider.swift",
  "utf8",
).match(/private static let bridge = #"""([\s\S]*?)"""#/)?.[1];

function run(status: number | number[]) {
  if (!source) throw new Error("Kimi bridge source is missing");
  const events: Array<Record<string, unknown>> = [];
  let settled: (events: Array<Record<string, unknown>>) => void = () => {};
  const terminal = new Promise<Array<Record<string, unknown>>>((resolve) => { settled = resolve; });
  const account = { getCurrentUser: async () => ({ user: { id: "test-user" } }) };
  const statuses = Array.isArray(status) ? status : [status];
  let statusIndex = 0;
  let resumeCount = 0;
  const client = {
    chat: async function* (request: Record<string, unknown>) {
      expect(request.chatId).toBe("");
      expect((request.options as Record<string, unknown>).systemPrompt).toBe("Ox instructions");
      yield { event: { case: "chat", value: { id: "chat-1" } }, eventOffset: 1 };
      yield { event: { case: "message", value: { id: "message-1", role: 3, blocks: [] } }, eventOffset: 2 };
      yield { event: { case: "block", value: { id: "block-1", content: { case: "text", value: { content: "Hello" } } } }, op: 1, eventOffset: 3 };
      yield { event: { case: "block", value: { id: "block-1", content: { case: "text", value: { content: " world" } } } }, op: 2, eventOffset: 4 };
    },
    resumeChat: async function* () { resumeCount++; },
    getMessage: async () => ({ message: {
      status: statuses[Math.min(statusIndex++, statuses.length - 1)],
      blocks: [{ content: { case: "text", value: { content: "Hello world" } } }],
    } }),
  };
  const services = new Map<{ typeName: string }, object>([
    [{ typeName: "kimi.gateway.account.v1.UserService" }, account],
    [{ typeName: "kimi.gateway.chat.v1.ChatService" }, client],
  ]);
  const browser = globalThis as typeof globalThis & { window: any; document: any };
  browser.window = {
    webkit: { messageHandlers: { oxKimiGeneration: { postMessage(value: Record<string, unknown>) {
      events.push(value);
      if (value.type === "completed" || value.type === "failed") settled(events);
    } } } },
  };
  browser.document = { querySelector: () => ({ __vue_app__: { _context: { provides: { services: { serviceMap: services } } } } }) };
  new Function(source)();
  browser.window.__oxKimiRun("generation-1", "test prompt", "Ox instructions");
  return terminal.then(events => ({ events, resumeCount }));
}

test("Kimi bridge checks the current website account", async () => {
  if (!source) throw new Error("Kimi bridge source is missing");
  let userId: string | undefined;
  const services = new Map<{ typeName: string }, object>([
    [{ typeName: "kimi.gateway.account.v1.UserService" }, { getCurrentUser: async () => ({ user: { id: userId } }) }],
  ]);
  const browser = globalThis as typeof globalThis & { window: any; document: any };
  browser.window = { webkit: { messageHandlers: { oxKimiGeneration: { postMessage() {} } } } };
  browser.document = { querySelector: () => ({ __vue_app__: { _context: { provides: { services: { serviceMap: services } } } } }) };
  new Function(source)();
  expect(await browser.window.__oxKimiSignedIn()).toBe(false);
  userId = "test-user";
  expect(await browser.window.__oxKimiSignedIn()).toBe(true);
});

test("Kimi bridge emits ordered snapshots and confirms completed status", async () => {
  const { events } = await run(2);
  expect(events.filter(event => event.type !== "progress").map(event => event.type)).toEqual(["snapshot", "snapshot", "snapshot", "completed"]);
  expect(events.at(-2)?.text).toBe("Hello world");
});

test("Kimi bridge rejects a stream whose final message failed", async () => {
  const { events } = await run(5);
  expect(events.at(-1)?.type).toBe("failed");
  expect(events.some(event => event.type === "completed")).toBe(false);
});

test("Kimi bridge resumes the same generation before reporting completion", async () => {
  const { events, resumeCount } = await run([1, 2]);
  expect(resumeCount).toBe(1);
  expect(events.at(-1)?.type).toBe("completed");
});

test("Kimi bridge requests remote cancellation for the identified generation", async () => {
  if (!source) throw new Error("Kimi bridge source is missing");
  let ready: () => void = () => {};
  const identified = new Promise<void>(resolve => { ready = resolve; });
  let cancellations = 0;
  const account = { getCurrentUser: async () => ({ user: { id: "test-user" } }) };
  const client = {
    chat: async function* (_request: unknown, options: { signal: AbortSignal }) {
      yield { event: { case: "chat", value: { id: "chat-1" } }, eventOffset: 1 };
      yield { event: { case: "message", value: { id: "message-1", role: 3, blocks: [] } }, eventOffset: 2 };
      await new Promise<void>((_resolve, reject) => options.signal.addEventListener("abort", () => reject(new Error("aborted"))));
    },
    cancelChat: async () => { cancellations++; },
    getMessage: async () => ({ message: { status: 3 } }),
  };
  const services = new Map<{ typeName: string }, object>([
    [{ typeName: "kimi.gateway.account.v1.UserService" }, account],
    [{ typeName: "kimi.gateway.chat.v1.ChatService" }, client],
  ]);
  const browser = globalThis as typeof globalThis & { window: any; document: any };
  browser.window = { webkit: { messageHandlers: { oxKimiGeneration: { postMessage(value: Record<string, unknown>) {
    if (value.messageId === "message-1") ready();
  } } } } };
  browser.document = { querySelector: () => ({ __vue_app__: { _context: { provides: { services: { serviceMap: services } } } } }) };
  new Function(source)();
  browser.window.__oxKimiRun("generation-1", "test prompt");
  await identified;
  expect(await browser.window.__oxKimiCancel("generation-1")).toBe(true);
  expect(cancellations).toBe(1);
});

test("Kimi bridge keeps simultaneous generation events separate", async () => {
  if (!source) throw new Error("Kimi bridge source is missing");
  const terminal = new Map<string, (events: Array<Record<string, unknown>>) => void>();
  const events = new Map<string, Array<Record<string, unknown>>>([["first", []], ["second", []]]);
  const results = ["first", "second"].map(id => new Promise<Array<Record<string, unknown>>>(resolve => { terminal.set(id, resolve); }));
  const client = {
    chat: async function* (request: any) {
      const id = request.message.blocks[0].content.value.content as string;
      yield { event: { case: "chat", value: { id: `chat-${id}` } }, eventOffset: 1 };
      await new Promise(resolve => setTimeout(resolve, id === "first" ? 3 : 0));
      yield { event: { case: "message", value: { id: `message-${id}`, role: 3, blocks: [] } }, eventOffset: 2 };
    },
    getMessage: async (request: { messageId: string }) => ({ message: { status: 2, blocks: [{ content: { case: "text", value: { content: request.messageId } } }] } }),
  };
  const services = new Map<{ typeName: string }, object>([
    [{ typeName: "kimi.gateway.account.v1.UserService" }, { getCurrentUser: async () => ({ user: { id: "test-user" } }) }],
    [{ typeName: "kimi.gateway.chat.v1.ChatService" }, client],
  ]);
  const browser = globalThis as typeof globalThis & { window: any; document: any };
  browser.window = { webkit: { messageHandlers: { oxKimiGeneration: { postMessage(value: Record<string, unknown>) {
    const id = value.id as string;
    const own = events.get(id)!;
    own.push(value);
    if (value.type === "completed" || value.type === "failed") terminal.get(id)?.(own);
  } } } } };
  browser.document = { querySelector: () => ({ __vue_app__: { _context: { provides: { services: { serviceMap: services } } } } }) };
  new Function(source)();
  browser.window.__oxKimiRun("first", "first");
  browser.window.__oxKimiRun("second", "second");
  const [first, second] = await Promise.all(results);
  expect(first.at(-2)?.text).toBe("message-first");
  expect(second.at(-2)?.text).toBe("message-second");
  expect(first.at(-1)?.type).toBe("completed");
  expect(second.at(-1)?.type).toBe("completed");
});
