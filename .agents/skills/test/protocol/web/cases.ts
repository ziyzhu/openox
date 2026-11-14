import { strict as assert } from "node:assert";
import { elements } from "../../../setup/scripts/ios.ts";
import { approveSecretUse, wait, type Harness } from "./harness.ts";
import { govSecurityCode } from "./sites/gov.ts";
import { accounts } from "./sites/shared.ts";

export type Case = { name: string; site: string; run: (h: Harness) => Promise<string> };

const [ada] = accounts as [typeof accounts[0]];

function attach(name: string): string {
  const domain = name.split(":")[1];
  return `await ox.service.attach({ purpose: "Attach fixture", domain: ${JSON.stringify(domain)} });`;
}

export function invokeScript(name: string, input: unknown = {}, extra: Record<string, unknown> = {}): string {
  if (name.endsWith(":login")) {
    const providers: Record<string, string> = {
      "mail.ox-suite.localhost": "accounts.ox-suite.localhost",
      "ox-gov.localhost": "ox-govid.localhost",
      "ox-card.localhost": "ox-idp.localhost",
    };
    const provider = providers[name.split(":")[1]!];
    input = { auth: provider ? { type: "provider", service: `web:${provider}` } : { type: "password" }, ...input as object };
  }
  return `${attach(name)}
return await ox.service.invoke({ purpose: "Fixture case", name: ${JSON.stringify(name)}, input: ${JSON.stringify(input)}, ...${JSON.stringify(extra)} });`;
}

export function attemptScript(name: string, input: unknown = {}): string {
  return `${attach(name)}
try { return { value: await ox.service.invoke({ purpose: "Fixture case", name: ${JSON.stringify(name)}, input: ${JSON.stringify(input)} }) }; }
catch (error) { return { error: String(error?.message ?? error), code: error?.code ?? null }; }`;
}

async function driveLogin(h: Harness, domain: string, key: string, steps = 5) {
  let result = await h.turn(invokeScript(`web:${domain}:login`, { account: { $secret: key } }));
  assert.deepEqual(result, { interaction: "automatic", authentication: "unverified" });
  for (let step = 0; step < steps; step++) {
    await Bun.sleep(700);
    const state = await h.turn(`return await ox.web.browser.getPageState({ service: ${JSON.stringify(domain)}, purpose: "Inspect login document" });`);
    const frame = state.frames.find((frame: { isMainFrame: boolean }) => frame.isMainFrame);
    assert.ok(frame?.serviceID, "the live document has no service");
    if (frame.serviceID === `web:${domain}`) {
      const sessions = await h.turn(invokeScript(`web:${domain}:listSessions`, {}, { frameId: frame.id }));
      if (sessions.length) return sessions;
    }
    result = await h.turn(invokeScript(`${frame.serviceID}:login`, { account: { $secret: key } }, { frameId: frame.id }));
    assert.deepEqual(result, { interaction: "automatic", authentication: "unverified" });
  }
  return [];
}

async function signIn(h: Harness, domain: string, key: string) {
  await h.saveLogin(key, `web:${domain}`, ada);
  const sessions = await driveLogin(h, domain, key);
  assert.deepEqual(sessions.map((session: { id: string }) => session.id), [ada.id]);
  return sessions;
}

export const cases: Case[] = [
  {
    name: "ssr-public-read", site: "ssr",
    async run(h) {
      const result = await h.turn(invokeScript("web:ox-ssr.localhost:listArticles"));
      assert.deepEqual(result.articles.map((item: { id: string }) => item.id), ["a1", "a2"]);
      return "public action read hydration data without a session";
    },
  },
  {
    name: "ssr-signed-out", site: "ssr",
    async run(h) {
      assert.deepEqual(await h.turn(invokeScript("web:ox-ssr.localhost:listSessions")), []);
      const denied = await h.turn(attemptScript("web:ox-ssr.localhost:getInbox"));
      assert.ok(denied.error, "protected action succeeded without a session");
      assert.equal(h.site("ssr").counters.inbox ?? 0, 0, "protected action reached the website");
      return "discovery returned no accounts and the protected action failed before dispatch";
    },
  },
  {
    name: "ssr-auto-login", site: "ssr",
    async run(h) {
      const login = await signIn(h, "ox-ssr.localhost", "fixture-ssr-ada");
      assert.ok(login.length);
      const counters = h.site("ssr").counters;
      assert.equal(counters.passwordSubmissions, 1, "automatic login must submit the password exactly once");
      assert.equal(counters.passwordRejections ?? 0, 0);
      const sessions = await h.turn(invokeScript("web:ox-ssr.localhost:listSessions"));
      assert.deepEqual(sessions.map((session: { id: string }) => session.id), [ada.id]);
      const inbox = await h.turn(invokeScript("web:ox-ssr.localhost:getInbox"));
      assert.equal(inbox.account, ada.id);
      return "saved login completed the two-page username and password flow with one submission and a verified session";
    },
  },
  {
    name: "chat-model-generation", site: "chat",
    async run(h) {
      const login = await signIn(h, "ox-chat.localhost", "fixture-chat-ada");
      assert.ok(login.length);
      assert.equal(h.site("chat").counters.passwordSubmissions, 1, "same-page login must submit once");
      const { models } = await h.turn(invokeScript("web:ox-chat.localhost:listModels"));
      assert.deepEqual(models.map((model: { id: string }) => model.id), ["fixture-fast", "fixture-slow"]);
      const completed = await h.turn(`${submitScript("fixture-fast", "hello fixtures")}
let cursor = 0, text = "", done = false;
for (let attempt = 0; attempt < 40 && !done; attempt++) {
  const read = await conversation({ operation: "read", submissionId: started.submissionId, after: cursor, waitMilliseconds: 1000 });
  cursor = read.nextCursor;
  for (const event of read.events) { if (event.type === "text") text = event.text; if (event.type === "completed") done = true; if (event.type === "failed") throw Error(event.message); }
}
return { text, done };`);
      assert.deepEqual(completed, { text: "Echo from Fixture Fast: hello fixtures", done: true });
      const cancelled = await h.turn(`${submitScript("fixture-slow", "please stop")}
const first = await conversation({ operation: "read", submissionId: started.submissionId, after: 0, waitMilliseconds: 1000 });
const cancel = await conversation({ operation: "cancel", submissionId: started.submissionId });
return { streamed: first.events.some(event => event.type === "text"), status: cancel.status };`);
      assert.deepEqual(cancelled, { streamed: true, status: "cancelled" });
      await Bun.sleep(500);
      assert.equal(h.site("chat").counters.cancelledStreams, 1, "cancellation must abort the website stream");
      return "same-page login, model listing, streamed generation and mid-stream cancellation reached the website as expected";
    },
  },
  {
    name: "gql-page-api", site: "gql",
    async run(h) {
      const login = await signIn(h, "ox-gql.localhost", "fixture-gql-ada");
      assert.ok(login.length);
      const before = await h.turn(invokeScript("web:ox-gql.localhost:listNotes"));
      assert.deepEqual(before.notes.map((note: { id: string }) => note.id), ["n1"]);
      const created = await h.turn(invokeScript("web:ox-gql.localhost:addNote", { title: "From Ox" }),
        prompt => /addNote/.test(prompt.prompt) ? "Approve" : approveSecretUse(prompt));
      assert.deepEqual(created, { id: "n2", title: "From Ox" });
      assert.ok(h.prompts.some(prompt => /addNote/.test(prompt)), "approval-required write was not confirmed");
      assert.equal(h.site("gql").counters.csrfRejections ?? 0, 0, "page API calls must carry the CSRF token");
      return "in-page GraphQL reads and an approved write carried the CSRF token with no rejections";
    },
  },
  {
    name: "suite-provider-hop", site: "suite",
    async run(h) {
      await h.saveLogin("fixture-suite-ada", "web:accounts.ox-suite.localhost", ada);
      await h.turn(`return await ox.service.attach({ purpose: "Attach provider", domain: "accounts.ox-suite.localhost" });`);
      const login = await driveLogin(h, "mail.ox-suite.localhost", "fixture-suite-ada");
      assert.ok(login.length);
      assert.equal(h.site("suite").counters.passwordSubmissions, 1, "provider login must submit once");
      const sessions = await h.turn(invokeScript("web:mail.ox-suite.localhost:listSessions"));
      assert.deepEqual(sessions.map((session: { id: string }) => session.id), [ada.id]);
      const inbox = await h.turn(invokeScript("web:mail.ox-suite.localhost:getInbox"));
      assert.equal(inbox.account, ada.id);
      return "a provider-owned saved login signed in on the same-site accounts service and the destination verified the shared session";
    },
  },
  {
    name: "gov-auth-selection", site: "gov",
    async run(h) {
      const result = await h.turn(invokeScript("web:ox-gov.localhost:login"));
      assert.deepEqual(result, { interaction: "automatic", authentication: "unverified" });
      const state = await h.turn(`return await ox.web.browser.getPageState({ service: "ox-gov.localhost", purpose: "Inspect selected provider" });`);
      const frame = state.frames.find((frame: { isMainFrame: boolean }) => frame.isMainFrame);
      assert.equal(frame.serviceID, "web:ox-govid.localhost");
      assert.equal(h.site("gov").counters.authStarts, 1);
      assert.equal(h.site("gov").counters.passwordSubmissions ?? 0, 0);
      return "an explicit provider method started authorization without credentials or an implicit manual handoff";
    },
  },
  {
    name: "gov-provider-continuity", site: "gov",
    async run(h) {
      const attached = await h.turn(`return await ox.service.attach({ purpose: "Inspect authentication methods", domain: "ox-gov.localhost" });`);
      assert.deepEqual(attached.auth, [{ type: "provider", service: "web:ox-govid.localhost" }]);
      for (const input of [{}, { auth: { type: "password" } }, { auth: { type: "provider", service: "web:other.localhost" } }]) {
        const denied = await h.turn(attemptScript("web:ox-gov.localhost:login", input));
        assert.ok(denied.error, "missing or unadvertised authentication method was accepted");
      }
      assert.equal(h.site("gov").counters.authStarts ?? 0, 0, "invalid auth selection reached the website");
      await h.saveLogin("fixture-govid-ada", "web:ox-govid.localhost", ada);
      await h.turn(`return await ox.service.attach({ purpose: "Attach provider", domain: "ox-govid.localhost" });`);
      await driveLogin(h, "ox-gov.localhost", "fixture-govid-ada", 3);
      const login = await h.turn(`const state = await ox.web.browser.getPageState({ service: "ox-gov.localhost", purpose: "Inspect provider challenge" });
const frame = state.frames.find(frame => frame.isMainFrame);
return await ox.service.invoke({ purpose: "Complete session verification", name: "web:ox-govid.localhost:login", frameId: frame.id, input: { auth: { type: "password" }, interaction: "manual" } });`);
      assert.equal(login?.status, "awaiting_user");
      const counters = h.site("gov").counters;
      assert.equal(counters.authStarts, 1, "the destination must start provider authorization once");
      assert.equal(counters.passwordSubmissions, 1, "the provider handler must submit the password once on the same page");
      await h.waitMatching(/^conversation\.service\.login\..+\.done$/);
      await h.tapMatching(/^serviceInspector\.open\./);
      await h.ios.wait({ id: "serviceHandoff.done" }, { timeout: 10_000, stable: 800 });
      await h.screenshot("gov-session-verification");
      await h.fillWeb("Security code", govSecurityCode);
      await h.pressReturn();
      const deadline = Date.now() + 10_000;
      while (!counters.codeSubmissions && Date.now() < deadline) await Bun.sleep(100);
      assert.equal(counters.codeSubmissions, 1, "the security code was not submitted");
      await h.ios.tap({ id: "serviceHandoff.done" }, { stable: 300 });
      await h.idle(prompt => /remember|save/i.test(prompt.prompt) ? wait : undefined);
      await h.turn(`const state = await ox.web.browser.getPageState({ service: "ox-gov.localhost", purpose: "Inspect authentication callback" });
const frame = state.frames.find(frame => frame.isMainFrame);
if (frame.serviceID === "web:ox-govid.localhost") return await ox.service.invoke({ purpose: "Finish provider return", name: "web:ox-govid.localhost:login", frameId: frame.id, input: { auth: { type: "password" }, account: { $secret: "fixture-govid-ada" } } });
return null;`);
      await Bun.sleep(700);
      assert.equal(counters.callbacks, 1, "the authentication callback must complete after Done");
      assert.equal(counters.callbackRejections ?? 0, 0);
      assert.equal(counters.authStarts, 1, "Done must not restart provider authorization");
      const sessions = await h.turn(invokeScript("web:ox-gov.localhost:listSessions"));
      assert.deepEqual(sessions.map((session: { id: string }) => session.id), [ada.username]);
      const cases = await h.turn(invokeScript("web:ox-gov.localhost:getCases"));
      assert.equal(cases.account, ada.username);
      return "destination and provider handlers advanced one page, the manual security code returned through the callback after Done, and the intended destination account was verified";
    },
  },
  {
    name: "card-iframe-handoff", site: "card",
    async run(h) {
      const login = await h.turn(invokeScript("web:ox-card.localhost:login", { interaction: "manual" }));
      assert.equal(login?.status, "awaiting_user", `expected a manual handoff, got ${JSON.stringify(login)}`);
      await h.waitMatching(/^conversation\.service\.login\..+\.done$/);
      await h.tapMatching(/^serviceInspector\.open\./);
      await h.ios.wait({ id: "serviceHandoff.done" }, { timeout: 10_000, stable: 800 });
      await h.screenshot("card-handoff");
      await h.fillWeb("Email", ada.username);
      await h.fillWeb("Password", ada.password);
      await h.pressReturn();
      const deadline = Date.now() + 10_000;
      while (!h.site("card").counters.exchanges && Date.now() < deadline) await Bun.sleep(200);
      assert.equal(h.site("card").counters.exchanges, 1, "the nested widget did not complete the code exchange");
      await h.ios.tap({ id: "serviceHandoff.done" }, { stable: 300 });
      await h.ios.wait({ id: "secret-entry-dont-save" }, { timeout: 20_000 });
      await h.screenshot("card-remember");
      const remember = elements(await h.ios.describe()).map(element => element.AXLabel ?? "").find(label => label.startsWith("Remember this login"));
      assert.match(remember ?? "", /ox-idp\.localhost/, "the captured login must belong to the identity provider that owns the nested frame");
      await h.ios.tap({ id: "secret-entry-dont-save" }, { stable: 300 });
      await h.idle(prompt => /remember|save/i.test(prompt.prompt) ? wait : undefined);
      const sessions = await h.turn(invokeScript("web:ox-card.localhost:listSessions"));
      assert.deepEqual(sessions.map((session: { id: string }) => session.id), [ada.id]);
      return "manual login inside a nested cross-site iframe verified the destination and offered to remember the login for the identity provider";
    },
  },
];

function submitScript(modelId: string, text: string): string {
  const input = { operation: "submit", conversationRef: null, accountId: null, modelId, messages: [{ role: "user", text }], attachments: [], options: { temperature: null, maxTokens: null } };
  return `await ox.service.attach({ purpose: "Attach fixture", domain: "ox-chat.localhost" });
const conversation = input => ox.service.invoke({ purpose: "Website conversation", name: "web:ox-chat.localhost:conversation", input });
const started = await conversation(${JSON.stringify(input)});`;
}
