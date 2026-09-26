import { expect, test } from "bun:test";
import { serviceSource } from "../fixtures/model-service-source";

const source = serviceSource("gemini.google.com");
const parser = source.slice(source.indexOf("function parseModelResponse"), source.indexOf("function createModelSite"));
const parse = new Function(parser + "; return parseModelResponse;")();

function frame(text: string, complete = false, conversation = "c_1234", message = "r_abcd") {
  const candidate: any[] = ["rc_5678", [text]];
  candidate[8] = [complete ? 2 : 1];
  const data: any[] = [];
  data[1] = [conversation, message];
  data[4] = [candidate];
  data[14] = complete;
  return JSON.stringify([["wrb.fr", null, JSON.stringify(data)]]);
}

test("Gemini requires native completion markers instead of visible text or EOF", () => {
  const partial = frame("A visible answer");
  expect(() => parse(partial)).toThrow("without confirmed completion");
  expect(parse(partial + "\n" + frame("A finished answer", true))).toEqual({
    chatId: "1234", messageId: "r_abcd", text: "A finished answer",
  });
});

test("Gemini preserves final answer formatting and ignores unrelated wire metadata", () => {
  const answer = '```json\n{"action":"test"}\n```';
  expect(parse(")]}'\n\n100\n" + frame(answer, true) + '\n[["di",123]]\n')).toEqual({
    chatId: "1234", messageId: "r_abcd", text: answer,
  });
});

test("Gemini rejects mismatched, malformed, empty, and oversized completions", () => {
  expect(() => parse(frame("First", true) + "\n" + frame("Second", true, "c_9999"))).toThrow("identity changed");
  expect(() => parse(frame("First", true) + "\n" + frame("First", true, "c_1234", "r_ffff"))).toThrow("identity changed");
  expect(() => parse(frame("", true))).toThrow("Invalid completed");
  expect(() => parse(frame("Answer", true, "invalid"))).toThrow("Invalid completed");
  expect(() => parse("[invalid")).toThrow();
  expect(() => parse("a".repeat(4000001))).toThrow("size limit");
});

test("Gemini does not accept a partial candidate marked as a finished response", () => {
  const row = JSON.parse(frame("Partial", true));
  const data = JSON.parse(row[0][2]);
  data[4][0][8][0] = 1;
  row[0][2] = JSON.stringify(data);
  expect(() => parse(JSON.stringify(row))).toThrow("without confirmed completion");
});

test("Gemini reports context overflow before touching the website composer", async () => {
  const handlers: Record<string, {invoke(args: any): Promise<any>}> = {};
  const window = {ox: {install(register: any) { register({action: (id: string, handler: any) => { handlers[id] = handler; }}); }}};
  new Function("window", "console", source)(window, {log() {}});
  const {generationId} = await handlers.startModelGeneration!.invoke({
    modelId: "website-default", messages: [{role: "user", text: "x".repeat(32001)}],
    attachments: [], options: {temperature: null, maxTokens: null},
  });
  const result = await handlers.readModelGeneration!.invoke({generationId, after: 0, waitMilliseconds: 0});
  expect(result.events).toEqual([{
    type: "failed", kind: "contextOverflow", message: "Gemini context exceeds the website input limit of 32000 characters",
  }]);
});

for (const transport of ["fetch", "xhr"] as const) {
  test(`Gemini captures native ${transport} once and confirms the submitted conversation`, async () => {
    const events: any[] = [];
    let submissions = 0;
    let complete!: () => void;
    const finished = new Promise<void>(resolve => { complete = resolve; });
    class XHR {
      status = 200;
      responseText = frame("Verified answer", true);
      listeners: (() => void)[] = [];
      open(_method?: string, _url?: string) {}
      addEventListener(_event: string, callback: () => void) { this.listeners.push(callback); }
      send() { this.listeners.forEach(callback => callback()); }
    }
    const window = {fetch: async (_url?: string) => new Response(frame("Verified answer", true))};
    const bridge = source.slice(source.indexOf("function createModelSite"), source.indexOf("async function modelCatalog"));
    const make = new Function("window", "XMLHttpRequest", "location", "send", "signInState", "wait", "cid", "messages", "clean", "console", parser + bridge + ";return createModelSite;");
    const site = make(window, XHR, {href: "https://gemini.google.com/app", origin: "https://gemini.google.com"}, async (_prompt: string, _id: string, beforeSubmit: () => void) => {
      beforeSubmit();
      submissions++;
      const url = "/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate";
      if (transport === "fetch") await window.fetch(url);
      else { const xhr = new XHR(); xhr.open("POST", url); xhr.send(); }
    }, async () => ({signedIn: true}), async (predicate: () => boolean) => { if (!predicate()) throw Error("Conversation mismatch"); }, () => "1234", () => [{role: "user", text: "Synthetic prompt"}], (text: string) => text, {log() {}})((event: any) => {
      events.push(event);
      if (["completed", "failed"].includes(event.type)) complete();
    });
    site.start("generation-1", "Synthetic prompt");
    await finished;
    expect(submissions).toBe(1);
    expect(events.map(event => event.type)).toEqual(["snapshot", "completed"]);
    expect(events[0].text).toBe("Verified answer");
    expect(site.cancel("generation-1")).toBe("completed");
    expect(() => site.start("oversized", "a".repeat(32001))).toThrow("context exceeds");
    expect(submissions).toBe(1);
  });
}

for (const submitted of [false, true]) {
  test(`Gemini cancellation is truthful ${submitted ? "after" : "before"} submission`, async () => {
    let submissions = 0;
    const window = {fetch: (_url?: string) => new Promise<Response>(() => {})};
    class XHR { open() {} send() {} }
    const bridge = source.slice(source.indexOf("function createModelSite"), source.indexOf("async function modelCatalog"));
    const make = new Function("window", "XMLHttpRequest", "location", "send", "signInState", "console", parser + bridge + ";return createModelSite;");
    const site = make(window, XHR, {href: "https://gemini.google.com/app", origin: "https://gemini.google.com"}, async (_prompt: string, _id: string, beforeSubmit: () => void) => {
      beforeSubmit();
      submissions++;
      return await window.fetch("/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate");
    }, async () => ({signedIn: true}), {log() {}})(() => {});
    site.start("generation-1", "Synthetic prompt");
    if (submitted) await Promise.resolve();
    expect(site.cancel("generation-1")).toBe(submitted ? "unsupported" : "cancelled");
    await Promise.resolve();
    expect(submissions).toBe(submitted ? 1 : 0);
  });
}
