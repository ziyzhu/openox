import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const swift = readFileSync("apps/ios/Ox/Host/Agent/LLM/Providers/ClaudeWebsiteProvider.swift", "utf8");
const authentication = swift.match(/private static let authentication = #"""([\s\S]*?)"""#/)?.[1];
const submission = swift.match(/private static let submission = #"""([\s\S]*?)"""#/)?.[1];
const reconciliation = swift.match(/private static let reconciliation = #"""([\s\S]*?)"""#/)?.[1];
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor as new (...args: string[]) => (...args: unknown[]) => Promise<any>;

test("Claude website authentication recognizes the shared Ox session", async () => {
  if (!authentication) throw new Error("Claude authentication source is missing");
  const check = new AsyncFunction("fetch", authentication);
  expect(await check(async () => Response.json({ account: null }))).toBe(false);
  expect(await check(async () => Response.json({ account: { uuid: "account-1", memberships: [] } }))).toBe(true);
});

test("Claude website submission accepts one verified draft", async () => {
  if (!submission) throw new Error("Claude submission source is missing");
  const run = new AsyncFunction("prompt", "location", "document", submission);
  let draft = "";
  let clicks = 0;
  const input = { get innerText() { return draft; }, focus() {}, getClientRects: () => [1] };
  const button = { disabled: false, getClientRects: () => [1], getAttribute: () => null, click() { clicks++; } };
  const document = {
    querySelector: (selector: string) => selector.includes("chat-input-send") ? button : input,
    execCommand: (_command: string, _showUI: boolean, value: string) => { draft = value; return true; },
  };
  expect(await run("test prompt", { pathname: "/new" }, document)).toEqual({ status: "submitted" });
  expect(clicks).toBe(1);
  expect((await run("second prompt", { pathname: "/new" }, document)).status).toBe("failed");
  expect(clicks).toBe(1);
});

test("Claude read-back requires a matching user turn and finished assistant DOM", async () => {
  if (!reconciliation) throw new Error("Claude read-back source is missing");
  const run = new AsyncFunction("prompt", "location", "fetch", "document", reconciliation);
  const location = { pathname: "/chat/11111111-1111-1111-1111-111111111111" };
  let streaming = false;
  const document = { querySelectorAll: () => [{ getAttribute: () => streaming ? "true" : "false", innerText: "final reply" }] };
  const fetch = async (url: string) => url.includes("bootstrap")
    ? Response.json({ account: { memberships: [{ organization: { uuid: "org-1" } }] } })
    : Response.json({ uuid: "11111111-1111-1111-1111-111111111111", chat_messages: [
      { uuid: "user-1", sender: "human", text: "test prompt" },
      { uuid: "assistant-1", sender: "assistant", parent_message_uuid: "user-1", text: "final reply" },
    ] });
  expect(await run("test prompt", location, fetch, document)).toEqual({
    status: "complete", chatId: location.pathname.slice(6), messageId: "assistant-1", text: "final reply",
  });
  streaming = true;
  expect(await run("test prompt", location, fetch, document)).toEqual({ status: "pending" });
  streaming = false;
  expect(await run("different prompt", location, fetch, document)).toEqual({
    status: "failed", message: "Claude conversation did not contain the submitted prompt",
  });
});
