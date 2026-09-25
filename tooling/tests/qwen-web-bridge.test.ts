import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const source = readFileSync(
  "apps/ios/Ox/Host/Agent/LLM/Providers/QwenWebsiteProvider.swift",
  "utf8",
).match(/private static let bridge = #"""([\s\S]*?)"""#/)?.[1];

function session(chunks: string[], finalText = "Hello world", holdOpen = false, signedIn = true, authDelayMs = 0) {
  if (!source) throw new Error("Qwen bridge source is missing");
  const events: Array<Record<string, unknown>> = [];
  let settled: (events: Array<Record<string, unknown>>) => void = () => {};
  const terminal = new Promise<Array<Record<string, unknown>>>(resolve => { settled = resolve; });
  let identified: () => void = () => {};
  const responseIdentified = new Promise<void>(resolve => { identified = resolve; });
  let streamController: ReadableStreamDefaultController<Uint8Array> | undefined;
  const requests: Array<{ path: string; options: Record<string, any> }> = [];
  const request = async (path: string, options: Record<string, any>) => {
    if (path === "__markers__") return { success: false, data: { code: String(options["Accept-Language"] || options.responseType || options.baseURL) } };
    requests.push({ path, options });
    if (path === "/auths/") {
      if (authDelayMs) await new Promise(resolve => setTimeout(resolve, authDelayMs));
      return signedIn
        ? { success: true, data: { userId: "user-1" } }
        : { success: false, data: { code: "ERR_UNKNOWN_ERROR", message: "401 Unauthorized" } };
    }
    if (path === "/chats/new") return { success: true, data: { id: "chat-1" } };
    if (path === "/chat/completions") {
      const stream = new ReadableStream({ start(controller) {
        streamController = controller;
        for (const chunk of chunks) controller.enqueue(new TextEncoder().encode(chunk));
        if (!holdOpen) controller.close();
      } });
      return { success: true, data: stream, isStream: true };
    }
    if (path === "/chats/chat-1") return { success: true, data: { chat: { messages: [{ id: "response-1", role: "assistant", done: true, content: finalText }] } } };
    if (path === "/chat/completions/stop") return { success: true, data: { status: true } };
    throw new Error(`Unexpected path ${path}`);
  };
  const store = Object.assign(() => {}, { getState: () => ({ selectedModelIds: ["qwen-model"] }) });
  const browser = globalThis as typeof globalThis & { window: any; document: any; __qwenImport: any };
  browser.window = { webkit: { messageHandlers: { oxQwenGeneration: { postMessage(value: Record<string, unknown>) {
    events.push(value);
    if (value.messageId === "response-1") identified();
    if (value.type === "completed" || value.type === "failed") settled(events);
  } } } } };
  browser.document = { scripts: [{ src: "https://assets.alicdn.com/g/qwenweb/qwen-chat-fe/0.2.91/js/main.js" }] };
  browser.__qwenImport = async () => ({ request, store });
  new Function(source.replace("await import(script.src)", "await globalThis.__qwenImport(script.src)"))();
  browser.window.__oxQwenRun("generation-1", "test prompt");
  return { terminal, responseIdentified, closeStream: () => streamController?.close(), requests, browser };
}

const created = 'data: {"response.created":{"chat_id":"chat-1","response_id":"response-1"}}\n\n';
const delta = 'data: {"choices":[{"delta":{"role":"assistant","phase":"answer","content":"Hello world"}}]}\n\n';

test("Qwen bridge submits through the page client and confirms completion", async () => {
  const { terminal, requests } = session([created.slice(0, 20), created.slice(20) + delta, "data: [DONE]\n\n"]);
  const events = await terminal;
  expect(events.filter(event => event.type === "snapshot").map(event => event.text)).toEqual(["Hello world", "Hello world"]);
  expect(events.at(-1)?.type).toBe("completed");
  expect(requests.find(value => value.path === "/chat/completions")?.options.data.messages[0].content).toBe("test prompt");
});

test("Qwen bridge rejects EOF without a terminal event", async () => {
  const { terminal } = session([created + delta]);
  const events = await terminal;
  expect(events.at(-1)?.type).toBe("failed");
  expect(events.some(event => event.type === "completed")).toBe(false);
});

test("Qwen bridge reports the website's logged-out response", async () => {
  const { terminal, requests, browser } = session([], "", false, false);
  expect(await browser.window.__oxQwenSignedIn()).toBe(false);
  expect((await terminal).at(-1)?.type).toBe("failed");
  expect(requests.some(value => value.path === "/chats/new")).toBe(false);
});

test("Qwen bridge accepts CRLF event boundaries split across chunks", async () => {
  const frames = (created + delta + "data: [DONE]\n\n").replaceAll("\n", "\r\n");
  const cut = frames.indexOf("\r\n\r\n") + 1;
  const { terminal } = session([frames.slice(0, cut), frames.slice(cut)]);
  expect((await terminal).at(-1)?.type).toBe("completed");
});

test("Qwen bridge sends the identified response to the stop endpoint", async () => {
  const { terminal, responseIdentified, closeStream, requests, browser } = session([created + delta], "Hello world", true);
  await responseIdentified;
  expect(await browser.window.__oxQwenCancel("generation-1")).toBe(true);
  expect(requests.find(value => value.path === "/chat/completions/stop")?.options.data).toEqual({ chat_id: "chat-1", response_id: "response-1" });
  closeStream();
  await terminal;
  expect(requests.find(value => value.path === "/chat/completions")?.options.responseType).toBe("stream");
});

test("Qwen bridge cancels before submitting a completion", async () => {
  const { browser, requests } = session([], "", false, true, 20);
  expect(await browser.window.__oxQwenCancel("generation-1")).toBe(true);
  await new Promise(resolve => setTimeout(resolve, 30));
  expect(requests.some(value => value.path === "/chats/new" || value.path === "/chat/completions")).toBe(false);
});
