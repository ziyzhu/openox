import { expect, test } from "bun:test";
import { modelSiteSource } from "../fixtures/model-service-source";

const source = modelSiteSource("www.kimi.com") + `
  async function identity() {
    const services = document.querySelector('#app').__vue_app__._context.provides.services.serviceMap;
    const client = [...services].find(([definition]) => definition.typeName === 'kimi.gateway.account.v1.UserService')[1];
    const result = await client.getCurrentUser();
    return result.user?.id ? result.user : null;
  }
  const site = createModelSite(value => window.webkit.messageHandlers.oxKimiGeneration.postMessage(value));
  window.__oxKimiRun = (id, prompt, systemPrompt) => site.start(id, prompt, '', systemPrompt);
  window.__oxKimiCancel = site.cancel;
  window.__oxKimiSignedIn = site.signedIn;`;

function run(status: number | number[], uploadStatus?: number) {
  if (!source) throw new Error("Kimi service source is missing");
  const events: Array<Record<string, unknown>> = [];
  let settled: (events: Array<Record<string, unknown>>) => void = () => {};
  const terminal = new Promise<Array<Record<string, unknown>>>((resolve) => { settled = resolve; });
  const account = { getCurrentUser: async () => ({ user: { id: "test-user" } }) };
  const statuses = Array.isArray(status) ? status : [status];
  let statusIndex = 0;
  let resumeCount = 0;
  let uploaded = false;
  let submitted = false;
  let uploadedBlocks: any[] = [];
  const client = {
    chat: async function* (request: Record<string, unknown>) {
      submitted = true;
      uploadedBlocks = (request.message as any).blocks.filter((block: any) => block.content.case === "file");
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
    [{ typeName: "kimi.gateway.file.v1.FileService" }, { getFileParseProgress: async () => {
      expect(uploaded).toBe(true);
      expect(submitted).toBe(false);
      return { progresses: [{ fileId: "file-1", status: uploadStatus }] };
    } }],
  ]);
  const browser = globalThis as typeof globalThis & { window: any; document: any };
  browser.window = {
    webkit: { messageHandlers: { oxKimiGeneration: { postMessage(value: Record<string, unknown>) {
      events.push(value);
      if (value.type === "completed" || value.type === "failed") settled(events);
    } } } },
  };
  if (uploadStatus !== undefined) browser.window.__oxWebsiteFiles = [new File([new Uint8Array([1, 2, 3])], "ox-1.png", { type: "image/png" })];
  const uploader = async (options: any) => {
    expect(options.baseURL + options.url).toBe("/apiv2-files/file/upload");
    const file = options.data.get("file") as File;
    expect(file.name).toBe("ox-1.png");
    expect([...new Uint8Array(await file.arrayBuffer())]).toEqual([1, 2, 3]);
    uploaded = true;
    return JSON.stringify({ file: { id: "file-1" } });
  };
  browser.document = { querySelector: () => ({ __vue_app__: { _context: { provides: { services: { serviceMap: services }, [Symbol("requestClient")]: uploader } } } }) };
  new Function(source)();
  browser.window.__oxKimiRun("generation-1", "test prompt", "Ox instructions");
  return terminal.then(events => ({ events, resumeCount, submitted, uploadedBlocks }));
}

test("Kimi service uses the shared service authentication result", async () => {
  if (!source) throw new Error("Kimi service source is missing");
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

test("Kimi service emits ordered snapshots and confirms completed status", async () => {
  const { events } = await run(2);
  expect(events.filter(event => event.type !== "progress").map(event => event.type)).toEqual(["snapshot", "snapshot", "snapshot", "completed"]);
  expect(events.at(-2)?.text).toBe("Hello world");
});

test("Kimi service rejects a stream whose final message failed", async () => {
  const { events } = await run(5);
  expect(events.at(-1)?.type).toBe("failed");
  expect(events.some(event => event.type === "completed")).toBe(false);
});

test("Kimi service resumes the same generation before reporting completion", async () => {
  const { events, resumeCount } = await run([1, 2]);
  expect(resumeCount).toBe(1);
  expect(events.at(-1)?.type).toBe("completed");
});

test("Kimi service requests remote cancellation for the identified generation", async () => {
  if (!source) throw new Error("Kimi service source is missing");
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

test("Kimi service keeps simultaneous generation events separate", async () => {
  if (!source) throw new Error("Kimi service source is missing");
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

test("Kimi uploads bytes and waits for parsing before attaching the file to chat", async () => {
  const { events, uploadedBlocks } = await run(2, 3);
  expect(events.at(-1)?.type).toBe("completed");
  expect(uploadedBlocks[0].content.value.id).toBe("file-1");
});

test("Kimi never submits a chat when attachment processing fails", async () => {
  const { events, submitted } = await run(2, 4);
  expect(events.at(-1)?.type).toBe("failed");
  expect(submitted).toBe(false);
});
