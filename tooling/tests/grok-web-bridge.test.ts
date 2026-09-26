import { expect, test } from "bun:test";
import { modelSiteSource, serviceSource } from "../fixtures/model-service-source";

const service = serviceSource("grok.com");
const source = service.slice(0, service.indexOf("window.ox.install")) + modelSiteSource("grok.com")
  + `const site = createModelSite(value => window.webkit.messageHandlers.oxGrokGeneration.postMessage(value));
     window.__oxGrokRun = site.start;`;


type BridgeEvent = { id: string; type: string; text?: string; message?: string; chatId?: string; messageId?: string };

function ndjson(lines: string[], holdOpen = false) {
  return new Response(new ReadableStream({
    start(controller) {
      const encoder = new TextEncoder();
      for (const line of lines) controller.enqueue(encoder.encode(line));
      if (!holdOpen) controller.close();
    },
  }), { status: 200, headers: { "content-type": "application/x-ndjson" } });
}

async function run(options: { holdOpen?: boolean; pending404?: boolean; pending?: boolean; signedIn?: boolean; authStatus?: number; finalText?: string; upload?: "ready" | "failed" | "existing" } = {}) {
  if (!source) throw new Error("Grok service source is missing");
  const events: BridgeEvent[] = [];
  let resolveTerminal: (events: BridgeEvent[]) => void = () => {};
  const terminal = new Promise<BridgeEvent[]>(resolve => { resolveTerminal = resolve; });
  let draft = "";
  let submissions = 0;
  let indexReads = 0;
  const chips: any[] = options.upload === "existing" ? [{}] : [];
  const uploadInput = {
    files: [] as File[],
    dispatchEvent() {
      expect(this.files[0].name).toBe("ox-image.png");
      expect(this.files[0].size).toBe(3);
      activeInput = {...input, editor: input.editor};
      input.editor = undefined as any;
      chips.push({__reactFiberTest: {memoizedProps: {
        fileName: "ox-image.png", metadata: options.upload === "failed" ? new Error("rejected") : {fileMetadataId: "file-1"},
      }}});
    },
  };
  const form = {querySelector: () => uploadInput, requestSubmit() { submissions++; void browser.window.fetch("/rest/app-chat/conversations/new", { method: "POST" }); }};
  const input = {
    textContent: "", focus() {}, getClientRects: () => [1], getAttribute: () => null,
    editor: { state: { doc: { get textContent() { return draft; } } }, commands: { insertContent(value: string) { draft = value; activeInput.textContent = value; return true; } } },
    closest: () => form,
  };
  let activeInput = input;
  const button = { disabled: false, getClientRects: () => [1], getAttribute: () => null };
  const browser = globalThis as typeof globalThis & { window: any; document: any; location: any; fetch: any };
  browser.location = { pathname: "/", href: "https://grok.com/" };
  browser.document = {
    querySelectorAll: (selector: string) => selector.includes("Conversation attachments") ? chips : [activeInput],
    querySelector: () => button,
  };
  browser.window = {
    fetch: async (url: string) => {
      if (url === "/rest/user-settings") return options.signedIn === false
        ? Response.json(options.authStatus === 400 ? { code: 3, message: "Only authenticated users" } : { code: 401, message: "Unauthorized" }, { status: options.authStatus ?? 401 })
        : Response.json({ enableMemory: true, excludeFromTraining: true });
      if (url === "/rest/app-chat/conversations/new") return ndjson([
        '{"result":{"conversation":{"conversationId":"chat-1"},"response":{"token":"Hello","isThinking":false}}}\n',
        '{"result":{"response":{"token":" world","isThinking":false,"modelResponse":{"responseId":"response-2","message":"Hello world"}}}}\n',
      ], options.holdOpen);
      if (url.endsWith("/response-node") && options.pending404 && indexReads++ === 0) return new Response(null, {status: 404});
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
  if (options.upload && options.upload !== "existing") browser.window.__oxWebsiteFiles = [new File([new Uint8Array([1, 2, 3])], "ox-image.png", {type: "image/png"})];
  (globalThis as any).DataTransfer = class {
    files: File[] = [];
    items = {add: (file: File) => this.files.push(file)};
  };
  browser.fetch = (...args: Parameters<typeof fetch>) => browser.window.fetch(...args);
  new Function(source)();
  browser.window.__oxGrokRun("generation-1", "test prompt");
  return { events: await terminal, submissions };
}

test("Grok service submits once, streams NDJSON, and confirms the server message", async () => {
  const { events, submissions } = await run();
  expect(submissions).toBe(1);
  expect(events.map(value => value.type)).toEqual(["snapshot", "snapshot", "completed"]);
  expect(events.at(-2)?.text).toBe("Hello world");
  expect(events.at(-1)?.chatId).toBe("chat-1");
});

test("Grok service rejects a server response that revises streamed text", async () => {
  const { events } = await run({ finalText: "Different answer" });
  expect(events.at(-1)?.type).toBe("failed");
  expect(events.some(value => value.type === "completed")).toBe(false);
});

test("Grok service does not submit when signed out", async () => {
  const { events, submissions } = await run({ signedIn: false });
  expect(submissions).toBe(0);
  expect(events.at(-1)?.type).toBe("failed");
});

test("Grok recognizes the website's authenticated-users-only response", async () => {
  const { events, submissions } = await run({ signedIn: false, authStatus: 400 });
  expect(events.at(-1)?.message).toContain("Sign in to Grok");
  expect(submissions).toBe(0);
});

test("Grok submits only after native attachment metadata is ready", async () => {
  const {events, submissions} = await run({upload: "ready"});
  expect(submissions).toBe(1);
  expect(events.at(-1)?.type).toBe("completed");
});

for (const upload of ["failed", "existing"] as const) {
  test(`Grok refuses submission with ${upload} attachments`, async () => {
    const {events, submissions} = await run({upload});
    expect(submissions).toBe(0);
    expect(events.at(-1)?.type).toBe("failed");
  });
}

test("Grok confirms the completed conversation while the captured stream stays open", async () => {
  const {events, submissions} = await run({holdOpen: true, pending404: true});
  expect(events.at(-1)?.type).toBe("completed");
  expect(events.at(-2)?.text).toBe("Hello world");
  expect(submissions).toBe(1);
});
