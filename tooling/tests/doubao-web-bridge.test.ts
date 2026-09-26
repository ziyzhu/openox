import { expect, test } from "bun:test";
import { serviceSource } from "../fixtures/model-service-source";

const source = serviceSource("doubao.com");
const parser = source.slice(source.indexOf("function parseModelResponse"), source.indexOf("function createModelSite"));
const parse = new Function(parser + "; return parseModelResponse;")();
const prompt = "Synthetic prompt";
const frame = (event: string, data: object) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
const block = (text: string, finished = false) => ({block_type: 10000, block_id: "block-1", content: {text_block: {text}}, is_finish: finished, patch_type: 1});
function response() {
  return [
    frame("SSE_ACK", {query_list: [{question_id: "111"}], ack_client_meta: {conversation_id: "222"}}),
    frame("FULL_MSG_NOTIFY", {message: {user_type: 1, conversation_id: "222", message_id: "111", content_block: [block(prompt)]}}),
    frame("STREAM_MSG_NOTIFY", {meta: {user_type: 2, conversation_id: "222", message_id: "333", bot_reply_message_id: "111"}, content: {content_block: [block("A")]}}),
    frame("STREAM_CHUNK", {message_id: "333", patch_op: [{patch_object: 1, patch_value: {content_block: [block("ns")]}}]}),
    frame("CHUNK_DELTA", {text: "wer\nwith formatting"}),
    frame("STREAM_CHUNK", {message_id: "333", patch_op: [{patch_object: 1, patch_value: {content_block: [block("", true)]}}, {patch_object: 50, patch_value: {ext: {is_finish: "1"}}}]}),
    frame("SSE_REPLY_END", {end_type: 1, msg_finish_attr: {msgid: "333"}}),
    frame("SSE_REPLY_END", {end_type: 2}),
    frame("SSE_REPLY_END", {end_type: 3}),
  ];
}

test("Doubao combines native text patches and requires correlated completion", () => {
  expect(parse(response().join(""), prompt)).toEqual({chatId: "222", messageId: "333", text: "Answer\nwith formatting"});
  for (const index of [0, 1, 2, 5, 6, 7, 8]) {
    expect(() => parse(response().filter((_, i) => i !== index).join(""), prompt)).toThrow();
  }
  expect(() => parse(response().join(""), "Different prompt")).toThrow();
});

test("Doubao verifies the full submitted prompt even when the page collapses it", () => {
  const longPrompt = "Synthetic context ".repeat(3000);
  const wire = response().join("").replace(prompt, longPrompt);
  expect(parse(wire, longPrompt).text).toBe("Answer\nwith formatting");
  expect(() => parse(wire, longPrompt.slice(0, 16000))).toThrow();
});

test("Doubao rejects changed identities, unsupported patches, errors, and oversized output", () => {
  const valid = response().join("");
  expect(() => parse(valid.replace('"msgid":"333"', '"msgid":"999"'), prompt)).toThrow("identity changed");
  expect(() => parse(valid.replaceAll('"patch_type":1', '"patch_type":2'), prompt)).toThrow("text patch");
  expect(() => parse(valid.replaceAll('"block_type":10000', '"block_type":999'), prompt)).toThrow("Unsupported");
  expect(() => parse(valid + frame("SSE_ERROR", {}), prompt)).toThrow("error");
  expect(() => parse("x".repeat(4000001), prompt)).toThrow("size limit");
});

for (const transport of ["fetch", "xhr"] as const) {
  test(`Doubao observes native ${transport} completion without resubmitting`, async () => {
    const events: any[] = [];
    let submissions = 0;
    let finish!: () => void;
    const done = new Promise<void>(resolve => { finish = resolve; });
    class XHR {
      status = 200;
      responseText = response().join("");
      listeners: (() => void)[] = [];
      open(_method?: string, _url?: string) {}
      addEventListener(_event: string, callback: () => void) { this.listeners.push(callback); }
      send() { this.listeners.forEach(callback => callback()); }
    }
    const window = {fetch: async (_url?: string) => new Response(response().join(""))};
    const bridge = source.slice(source.indexOf("function createModelSite"), source.indexOf("async function modelCatalog"));
    const create = new Function("window", "XMLHttpRequest", "location", "send", "signInState", "wait", "currentRef", "messages", "norm", "console", parser + bridge + ";return createModelSite;");
    const site = create(window, XHR, {href: "https://www.doubao.com/chat/", origin: "https://www.doubao.com"}, async (_prompt: string, _id: string, beforeSubmit: () => void) => {
      beforeSubmit();
      submissions++;
      if (transport === "fetch") await window.fetch("/chat/completion");
      else { const xhr = new XHR(); xhr.open("POST", "/chat/completion"); xhr.send(); }
    }, async () => ({signedIn: true}), async (predicate: () => boolean) => { if (!predicate()) throw Error("Conversation mismatch"); }, () => "222", () => [{role: "user", text: "Collapsed message"}], (text: string) => text, {log() {}})((event: any) => {
      events.push(event);
      if (["completed", "failed"].includes(event.type)) finish();
    });
    site.start("generation-1", prompt);
    await done;
    expect(submissions).toBe(1);
    expect(events.map(event => event.type)).toEqual(["snapshot", "completed"]);
    expect(events[0].text).toBe("Answer\nwith formatting");
    expect(site.cancel("generation-1")).toBe("completed");
  });
}

test("Doubao cancels before submission without sending", async () => {
  const bridge = source.slice(source.indexOf("function createModelSite"), source.indexOf("async function modelCatalog"));
  let authenticate!: (value: {signedIn: boolean}) => void;
  let submissions = 0;
  const signedIn = new Promise(resolve => { authenticate = resolve; });
  const create = new Function("signInState", "send", "console", bridge + ";return createModelSite;");
  const site = create(() => signedIn, async () => { submissions++; }, {log() {}})(() => {});
  site.start("generation-1", prompt);
  expect(site.cancel("generation-1")).toBe("cancelled");
  authenticate({signedIn: true});
  await Promise.resolve();
  expect(submissions).toBe(0);
});

test("Doubao does not claim remote cancellation after the native click", async () => {
  const bridge = source.slice(source.indexOf("function createModelSite"), source.indexOf("async function modelCatalog"));
  let submitted!: () => void;
  const clicked = new Promise<void>(resolve => { submitted = resolve; });
  const window = {fetch: async () => new Promise<Response>(() => {})};
  class XHR { open() {} send() {} }
  const create = new Function("window", "XMLHttpRequest", "location", "signInState", "send", "console", bridge + ";return createModelSite;");
  const site = create(window, XHR, {origin: "https://www.doubao.com", href: "https://www.doubao.com/chat/"}, async () => ({signedIn: true}), async (_prompt: string, _id: string, beforeSubmit: () => void) => {
    beforeSubmit();
    submitted();
  }, {log() {}})(() => {});
  site.start("generation-1", prompt);
  await clicked;
  expect(site.cancel("generation-1")).toBe("unsupported");
});

test("Doubao hidden-page frame fallback runs once and honors cancellation", () => {
  const timers = new Map<number, () => void>();
  const frames = new Map<number, (time: number) => void>();
  let next = 0, calls = 0;
  const window = {
    requestAnimationFrame(callback: (time: number) => void) { const id = ++next; frames.set(id, callback); return id; },
    cancelAnimationFrame(id: number) { frames.delete(id); },
  };
  const install = source.slice(0, source.indexOf("let lastSubmissionEvents"));
  new Function("window", "document", "setTimeout", "clearTimeout", "performance", install)(window, {hidden: true}, (callback: () => void) => { const id = ++next; timers.set(id, callback); return id; }, (id: number) => timers.delete(id), {now: () => 100});
  window.requestAnimationFrame(() => { calls++; });
  const native = [...frames.values()][0]!;
  [...timers.values()][0]!();
  native(100);
  expect(calls).toBe(1);
  expect(frames.size).toBe(0);
  const id = window.requestAnimationFrame(() => { calls++; });
  window.cancelAnimationFrame(id);
  expect(timers.size).toBe(0);
  expect(frames.size).toBe(0);
  expect(calls).toBe(1);
});
