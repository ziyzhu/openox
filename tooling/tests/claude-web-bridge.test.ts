import { expect, test } from "bun:test";
import { modelSiteSource } from "../fixtures/model-service-source";

const source = modelSiteSource("claude.ai");

async function submit(state: "ready" | "failed" | "existing" | "canceled" | "alternate") {
  const events: any[] = [];
  let finish!: () => void;
  const finished = new Promise<void>(resolve => { finish = resolve; });
  let submissions = 0;
  const tiles: any[] = state === "existing" ? [{querySelector: () => null}] : [];
  const editor = {innerText: "", focus() {}, getClientRects: () => [1]};
  let text = "";
  const nativeEditor = {state: {doc: {get textContent() {return text;}}}, commands: {insertContent(value: {type: string; text: string}) {expect(value.type).toBe("text"); text = value.text; activeEditor.innerText = value.text; return true;}}};
  const inputEditor = Object.assign(editor, {editor: nativeEditor});
  let activeEditor = inputEditor;
  const button = {disabled: false, getAttribute: () => null, getClientRects: () => [1], click() { submissions++; finish(); }};
  const input = {
    files: [] as File[],
    closest: () => ({querySelectorAll: () => tiles}),
    dispatchEvent() {
      expect(this.files[0].name).toBe("ox-document.pdf");
      expect(this.files[0].size).toBe(3);
      const props = {file: {file_name: "ox-document.pdf", file_uuid: "file-1", success: state !== "failed"}, pending: false};
      activeEditor = {...inputEditor};
      editor.focus = () => { throw new Error("Used a replaced composer"); };
      tiles.push({__reactFiberTest: state === "alternate" ? {memoizedProps: {file: {}, pending: true}, alternate: {memoizedProps: props}} : {memoizedProps: props}});
    },
  };
  const document = {
    querySelector: (selector: string) => selector.includes('input[data-testid="file-upload"]') ? input : selector.includes('chat-input-send') ? button : activeEditor,
  };
  class DataTransfer {
    files: File[] = [];
    items = {add: (file: File) => this.files.push(file)};
  }
  const window = {__oxWebsiteFiles: [new File([new Uint8Array([1, 2, 3])], "ox-document.pdf", {type: "application/pdf"})]};
  const create = new Function("window", "document", "location", "DataTransfer", source + "; return createModelSite;");
  const site = create(window, document, {pathname: "/new"}, DataTransfer)((event: any) => {
    events.push(event);
    finish();
  });
  site.start("generation-1", "Read the attached PDF");
  if (state === "canceled") expect(await site.cancel("generation-1")).toBe("cancelled");
  await finished;
  return {events, submissions};
}

for (const state of ["ready", "alternate"] as const) {
  test(`Claude submits after native file success in ${state} state`, async () => {
    const {events, submissions} = await submit(state);
    expect(events).toEqual([]);
    expect(submissions).toBe(1);
  });
}

const failures = {
  failed: "Claude could not process an attachment",
  existing: "Claude contains existing draft attachments",
  canceled: "Claude submission canceled",
};

for (const state of Object.keys(failures) as (keyof typeof failures)[]) {
  test(`Claude refuses submission with ${state} attachments`, async () => {
    const {events, submissions} = await submit(state);
    expect(events).toEqual([{id: "generation-1", type: "failed", message: failures[state]}]);
    expect(submissions).toBe(0);
  });
}
