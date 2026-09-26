import { expect, test } from "bun:test";
import { modelSiteSource } from "../fixtures/model-service-source";

const source = modelSiteSource("claude.ai").split("const submit = async (prompt, state) => {")[1]?.split("\n  };\n  return {")[0];
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

async function submit(state: "ready" | "failed" | "existing" | "canceled" | "alternate") {
  if (!source) throw new Error("Claude submission source is missing");
  let submissions = 0;
  const tiles: any[] = state === "existing" ? [{querySelector: () => null}] : [];
  const editor = {innerText: "", focus() {}, getClientRects: () => [1]};
  let text = "";
  const nativeEditor = {state: {doc: {get textContent() {return text;}}}, commands: {insertContent(value: {type: string; text: string}) {expect(value.type).toBe("text"); text = value.text; activeEditor.innerText = value.text; return true;}}};
  const inputEditor = Object.assign(editor, {editor: nativeEditor});
  let activeEditor = inputEditor;
  const button = {disabled: false, getAttribute: () => null, getClientRects: () => [1], click() { submissions++; }};
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
  const window = {__oxWebsiteFiles: [new File([new Uint8Array([1, 2, 3])], "ox-document.pdf", {type: "application/pdf"})], __oxClaudeCanceled: state === "canceled"};
  const result = await new AsyncFunction("window", "document", "location", "DataTransfer", "prompt", "state", source)(window, document, {pathname: "/new"}, DataTransfer, "Read the attached PDF", {canceled: state === "canceled", phase: "preparing"});
  return {result, submissions};
}

for (const state of ["ready", "alternate"] as const) {
  test(`Claude submits after native file success in ${state} state`, async () => {
    const {result, submissions} = await submit(state);
    expect(result.status).toBe("submitted");
    expect(submissions).toBe(1);
  });
}

for (const state of ["failed", "existing", "canceled"] as const) {
  test(`Claude refuses submission with ${state} attachments`, async () => {
    const {result, submissions} = await submit(state);
    expect(result.status).toBe("failed");
    expect(submissions).toBe(0);
  });
}
