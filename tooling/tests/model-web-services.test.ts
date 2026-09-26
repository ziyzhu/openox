import { expect, test } from "bun:test";
import { serviceSource } from "../fixtures/model-service-source";

type Event = { id: string; type: string; text?: string; message?: string };
const domains = ["qwen.ai", "www.kimi.com", "grok.com", "claude.ai", "gemini.google.com", "doubao.com"];

function session(domain: string) {
  const handlers: Record<string, { invoke(args: any): Promise<any> }> = {};
  let emit: (event: Event) => void = () => {};
  let submissions = 0;
  let submittedMessages = "";
  const window: any = { ox: { install(register: any) { register({action: (id: string, handler: any) => { handlers[id] = handler; }}); } } };
  new Function("window", "siteFactory", "console", serviceSource(domain) + `
    function createModelSite(send) { return siteFactory(send); }
    async function modelCatalog() { return [{id: 'website-default', input: ['text', 'image'], options: []}]; }
  `)(window, (send: (event: Event) => void) => {
    emit = send;
    return {
      start(_id: string, prompt: string) { submissions++; submittedMessages = prompt; },
      cancel() { return "requested"; },
      async observe() { return {status: "pending"}; },
    };
  }, {log() {}});
  const args = {modelId: "website-default", messages: [{role: "system", text: "Test instructions"}, {role: "user", text: "Test message"}], attachments: [], options: {temperature: null, maxTokens: null}};
  return {
    handlers, args, window, emit: (event: Event) => emit(event),
    start: (input = args) => handlers.startModelGeneration!.invoke(input),
    read: (generationId: string, after = 0) => handlers.readModelGeneration!.invoke({generationId, after, waitMilliseconds: 0}),
    submissions: () => submissions, submittedMessages: () => JSON.parse(submittedMessages),
  };
}

for (const domain of domains) {
  test(`${domain} retains terminal snapshots and never resubmits`, async () => {
    const run = session(domain);
    const {generationId} = await run.start();
    expect(run.submittedMessages().conversation).toEqual(run.args.messages);
    run.emit({id: generationId, type: "snapshot", text: "Hello"});
    expect(await run.read(generationId)).toEqual({nextCursor: 1, events: [{type: "text", text: "Hello"}]});
    run.emit({id: generationId, type: "snapshot", text: "Hello world"});
    run.emit({id: generationId, type: "completed"});
    const result = await run.read(generationId, 1);
    expect(result).toEqual({nextCursor: 3, events: [{type: "text", text: "Hello world"}, {type: "completed"}]});
    expect(await run.read(generationId, 1)).toEqual(result);
    run.emit({id: generationId, type: "snapshot", text: "Ignored after terminal"});
    expect(await run.read(generationId, 3)).toEqual({nextCursor: 3, events: []});
    await expect(run.start()).rejects.toThrow("already owns");
    expect(run.submissions()).toBe(1);
  });

  test(`${domain} rejects unsupported input before submission`, async () => {
    const run = session(domain);
    await expect(run.start({...run.args, modelId: "unknown"})).rejects.toThrow("unavailable");
    await expect(run.start({...run.args, options: {temperature: 1, maxTokens: null}} as any)).rejects.toThrow("options");
    run.window.__oxWebsiteFiles = [new File(["test"], "test.pdf", {type: "application/pdf"})];
    await expect(run.start({...run.args, attachments: [{id: 0, name: "test.pdf", mimeType: "application/pdf"}]} as any)).rejects.toThrow("attachment");
    expect(run.submissions()).toBe(0);
  });

  test(`${domain} fails revised text and rejects invalid cursors`, async () => {
    const run = session(domain);
    const {generationId} = await run.start();
    await expect(run.read(generationId, 1)).rejects.toThrow("cursor");
    run.emit({id: generationId, type: "snapshot", text: "original"});
    await run.read(generationId);
    run.emit({id: generationId, type: "snapshot", text: "revised"});
    const result = await run.read(generationId, 1);
    expect(result.events).toEqual([{type: "failed", message: "Model response revised published text or exceeded the size limit", kind: "provider"}]);
    expect((await run.read(generationId)).events[0].text).toBe("original");
  });

  test(`${domain} reports unconfirmed cancellation accurately`, async () => {
    const run = session(domain);
    const {generationId} = await run.start();
    expect(await run.handlers.cancelModelGeneration!.invoke({generationId})).toEqual({status: "requested"});
    run.emit({id: generationId, type: "completed"});
  });

  test(`${domain} bounds retained event history`, async () => {
    const run = session(domain);
    const {generationId} = await run.start();
    for (let index = 1; index <= 4096; index++) {
      run.emit({id: generationId, type: "snapshot", text: "a".repeat(index)});
      await run.read(generationId, index - 1);
    }
    const result = await run.read(generationId, 4095);
    expect(result.nextCursor).toBe(4096);
    expect(result.events[0].type).toBe("failed");
    expect(await run.read(generationId, 4096)).toEqual({nextCursor: 4096, events: []});
  });
}
