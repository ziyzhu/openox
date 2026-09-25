import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const source = readFileSync(
  "apps/ios/Ox/Host/Agent/LLM/Providers/GrokWebsiteProvider.swift",
  "utf8",
).match(/private static let bridge = #"""([\s\S]*?)"""#/)?.[1];
const reconciliationSource = readFileSync(
  "apps/ios/Ox/Host/Agent/LLM/Providers/GrokWebsiteProvider.swift",
  "utf8",
).match(/private static let reconciliation = #"""([\s\S]*?)"""#/)?.[1];

type BridgeEvent = { id: string; type: string; text?: string; message?: string; chatId?: string; messageId?: string };

function ndjson(lines: string[]) {
  return new Response(new ReadableStream({
    start(controller) {
      const encoder = new TextEncoder();
      for (const line of lines) controller.enqueue(encoder.encode(line));
      controller.close();
    },
  }), { status: 200, headers: { "content-type": "application/x-ndjson" } });
}

async function run(options: { pending?: boolean; signedIn?: boolean; finalText?: string } = {}) {
  if (!source) throw new Error("Grok bridge source is missing");
  const events: BridgeEvent[] = [];
  let resolveTerminal: (events: BridgeEvent[]) => void = () => {};
  const terminal = new Promise<BridgeEvent[]>(resolve => { resolveTerminal = resolve; });
  let draft = "";
  let submissions = 0;
  const input = {
    textContent: "", focus() {}, getClientRects: () => [1], getAttribute: () => null,
    editor: { state: { doc: { get textContent() { return draft; } } }, commands: { insertContent(value: string) { draft = value; input.textContent = value; return true; } } },
    closest: () => ({ requestSubmit() { submissions++; void browser.window.fetch("/rest/app-chat/conversations/new", { method: "POST" }); } }),
  };
  const button = { disabled: false, getClientRects: () => [1], getAttribute: () => null };
  const browser = globalThis as typeof globalThis & { window: any; document: any; location: any; fetch: any };
  browser.location = { pathname: "/", href: "https://grok.com/" };
  browser.document = {
    querySelectorAll: () => [input],
    querySelector: () => button,
  };
  browser.window = {
    fetch: async (url: string) => {
      if (url === "/rest/user-settings") return options.signedIn === false
        ? Response.json({ code: 401, message: "Unauthorized" }, { status: 401 })
        : Response.json({ enableMemory: true, excludeFromTraining: true });
      if (url === "/rest/app-chat/conversations/new") return ndjson([
        '{"result":{"conversation":{"conversationId":"chat-1"},"response":{"token":"Hello","isThinking":false}}}\n',
        '{"result":{"response":{"token":" world","isThinking":false,"modelResponse":{"responseId":"response-2","message":"Hello world"}}}}\n',
      ]);
      if (url.endsWith("/response-node")) return Response.json({ responseNodes: [{ responseId: "response-1" }, { responseId: "response-2" }], inflightResponses: options.pending ? ["response-2"] : [] });
      if (url.endsWith("/load-responses")) return Response.json({ responses: [
        { responseId: "response-1", sender: "human", message: "test prompt" },
        { responseId: "response-2", sender: "assistant", message: options.finalText ?? "Hello world", partial: false },
      ] });
      throw new Error(`Unexpected request ${url}`);
    },
    webkit: { messageHandlers: { oxGrokGeneration: { postMessage(value: BridgeEvent) {
      events.push(value);
      if (["completed", "failed"].includes(value.type)) resolveTerminal(events);
    } } } },
  };
  browser.fetch = (...args: Parameters<typeof fetch>) => browser.window.fetch(...args);
  new Function(source)();
  browser.window.__oxGrokRun("generation-1", "test prompt");
  return { events: await terminal, submissions };
}

test("Grok bridge submits once, streams NDJSON, and confirms the server message", async () => {
  const { events, submissions } = await run();
  expect(submissions).toBe(1);
  expect(events.map(value => value.type)).toEqual(["snapshot", "snapshot", "completed"]);
  expect(events.at(-2)?.text).toBe("Hello world");
  expect(events.at(-1)?.chatId).toBe("chat-1");
});

test("Grok bridge rejects a server response that revises streamed text", async () => {
  const { events } = await run({ finalText: "Different answer" });
  expect(events.at(-1)?.type).toBe("failed");
  expect(events.some(value => value.type === "completed")).toBe(false);
});

test("Grok bridge does not submit when signed out", async () => {
  const { events, submissions } = await run({ signedIn: false });
  expect(submissions).toBe(0);
  expect(events.at(-1)?.type).toBe("failed");
});

test("Grok read-back confirms the submitted prompt and completed response", async () => {
  if (!reconciliationSource) throw new Error("Grok read-back source is missing");
  const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor as new (...args: string[]) => (...args: unknown[]) => Promise<unknown>;
  const reconcile = new AsyncFunction("prompt", "chatId", "location", "fetch", reconciliationSource);
  const fetch = async (url: string) => url.endsWith("/response-node")
    ? Response.json({ responseNodes: [{ responseId: "user-1" }, { responseId: "assistant-1" }], inflightResponses: [] })
    : Response.json({ responses: [
      { responseId: "user-1", sender: "human", message: "test prompt" },
      { responseId: "assistant-1", sender: "assistant", message: "final reply", partial: false },
    ] });
  const location = { pathname: "/c/chat-1" };
  expect(await reconcile("test prompt", "", location, fetch)).toEqual({
    status: "complete", chatId: "chat-1", messageId: "assistant-1", text: "final reply",
  });
  expect(await reconcile("different prompt", "", location, fetch)).toEqual({
    status: "failed", message: "Grok conversation did not contain the submitted prompt",
  });
});
