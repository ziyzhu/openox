import standards from "../../../../packages/agent/src/functions/service/standard-actions.json";
import type { StubRule } from "../../../../packages/agent/evals/stubs";
import type { EvalCase } from "./types.ts";
import { readResource } from "./checks.ts";

const observed = "page" in standards.web.find(action => action.id === "login")!.outputSchema.properties!;
const domain = "ox-ssr.localhost";
const provider = "accounts.ox-suite.localhost";

function page(host: string, step: string) {
  const frame = { id: `${host}-${step}`, parentId: null, origin: `https://${host}`, isMainFrame: true, serviceID: `web:${host}`, attached: host === domain ? true : { $state: "providerAttached" } };
  const document = {
    headings: [step === "signed-in" ? "Inbox" : "Sign in"], messages: step === "rejected" ? ["Password rejected. Do not retry."] : [],
    controls: step === "signed-in" ? [] : [{ type: step === "identifier" ? "email" : step === "password" ? "password" : "button", label: step === "identifier" ? "Email" : step === "password" ? "Password" : step === "code" ? "Enter code" : step === "passkey" ? "Use passkey" : "Verify you are human", disabled: false, invalid: false }],
    truncated: false,
  };
  return { pageID: "fixture-page", navigationGeneration: 1, isLoading: false, frames: [frame], framesTruncated: false, document };
}

function state(host: string, step: string) {
  const value = page(host, step);
  return {
    ...value, url: `https://${host}/login`, title: "Fixture sign-in", estimatedProgress: 1,
    hasOnlySecureContent: true, isBlockedByScreenTime: false, fullscreenState: "notInFullscreen", frameId: value.frames[0]!.id,
    document: { ...value.document, scope: null, scopeFound: true, readyState: "complete", busy: false,
      dialogs: [], embeddedFrames: [], coverage: "Visible light DOM only",
      controls: value.document.controls.map(control => ({ ...control, id: null, name: null, role: "input", required: true })),
    },
  };
}

function listing(host: string) {
  return { pages: [{ pageId: "fixture-page", url: `https://${host}/login`, title: "Fixture sign-in", isLoading: false,
    busy: false, owned: true }], limit: 6 };
}

function frames(host: string, step: string) {
  return { frames: page(host, step).frames, framesTruncated: false };
}

function result(host: string, step: string) {
  return { interaction: "automatic", authentication: "unverified", ...observed ? { page: page(host, step) } : {} };
}

export function signinFixture(mode: "password" | "provider" | "manual" | "code" | "passkey" | "bot" | "cancelled" | "incomplete" | "rejected" | "existing" | "choose-manual"): EvalCase {
  const federated = mode === "provider";
  const manual = ["manual", "code", "passkey", "cancelled", "incomplete", "choose-manual"].includes(mode);
  const human = manual || mode === "bot";
  const blocked = ["cancelled", "incomplete", "rejected"].includes(mode);
  const saved = !manual || mode === "choose-manual";
  const humanStep = mode === "code" || mode === "passkey" ? mode : mode === "bot" ? "challenge" : "identifier";
  const owner = federated ? provider : domain;
  const auth = federated ? { type: "provider", service: `web:${provider}` } : { type: mode === "code" || mode === "passkey" ? mode : "password" };
  const service = (host: string) => ({ domain: host, name: "Sign-in Fixture", kind: "web", saved: true, attached: true, login: "unknown" });
  const sessions = [{ id: "ada", label: "Ada Fixture", url: `https://${domain}/` }];
  const inbox = { account: "ada", messages: [{ id: "m1", subject: "Welcome to the SSR fixture" }] };
  const inspection = (host: string) => ({
    ...service(host), standardActions: ["login", "listSessions"], auth: host === domain ? [auth] : [{ type: "password" }],
    secrets: !saved ? [] : [{ key: "fixture-ada", displayName: "Ada Fixture", type: "account", ...observed ? { serviceID: `web:${owner}` } : {} }],
    actions: host === domain ? { getInbox: { description: "Read this account's inbox", inputSchema: { type: "object", properties: {}, additionalProperties: false }, outputSchema: { type: "object" }, requireAuth: true, requireApproval: false } } : {},
  });
  const invoke: StubRule[] = [
    { args: { name: `web:${domain}:listSessions` }, when: { signedIn: true }, result: sessions },
    { args: { name: `web:${domain}:listSessions` }, result: [] },
    { args: { name: `web:${domain}:getInbox`, session: sessions[0] }, when: { signedIn: true }, result: inbox, set: { read: true } },
  ];
  if (manual) invoke.push({ args: { name: `web:${domain}:login`, input: { auth } }, when: { prepared: false }, result: result(domain, humanStep), set: { prepared: true } });
  else if (mode !== "existing") {
    if (federated) invoke.push({ args: { name: `web:${domain}:login`, frameId: `${domain}-identifier`, input: { auth } }, when: { step: 0 }, result: result(provider, "identifier"), set: { step: 1 } });
    invoke.push(
      { args: { name: `web:${owner}:login`, frameId: `${owner}-identifier`, input: { auth: { type: "password" }, account: { $secret: "fixture-ada", serviceID: `web:${owner}` } } }, when: { step: federated ? 1 : 0 }, result: result(owner, "password"), set: { step: 2 } },
      { args: { name: `web:${owner}:login`, frameId: `${owner}-password`, input: { auth: { type: "password" }, account: { $secret: "fixture-ada", serviceID: `web:${owner}` } } }, when: { step: 2 }, result: result(domain, mode === "bot" ? "challenge" : mode === "rejected" ? "rejected" : "signed-in"), set: { step: 3, signedIn: !blocked && !human, prepared: true } },
    );
  }
  return {
    task: mode === "existing" ? `Read my Ada Fixture inbox at ${domain}; reuse my current sign-in.` : mode === "choose-manual" ? `Sign me in to ${domain}, then tell me the subject of my inbox message.` : manual ? `Sign in ${mode === "code" || mode === "passkey" ? `using the advertised ${mode} method` : "manually"} to ${domain}, then tell me the subject of my inbox message.` : `Use my saved Ada Fixture login to sign in to ${domain}${federated ? " with its advertised account provider" : ""}, then tell me the subject of my inbox message.`,
    timeoutMs: 180_000,
    stubs: { state: { step: 0, prepared: false, presented: false, providerAttached: true, signedIn: mode === "existing", read: false }, functions: {
      "ox.service.inspect": [domain, provider].map(host => { const { domain: _, name: _name, kind: _kind, saved: _saved, attached: _attached, login: _login, ...rest } = inspection(host); return { args: { domain: host }, result: { service: service(host), ...rest } }; }),
      "ox.service.invoke": invoke,
      "ox.web.browser.newPage": [{ result: { pageId: "fixture-page", mainFrameId: `${domain}-identifier` } }],
      "ox.web.browser.pages": [
        { when: { step: 1 }, result: listing(provider) },
        { when: { step: 2 }, result: listing(owner) },
        { result: listing(domain) },
      ],
      "ox.web.browser.frames": [
        { when: { step: 3, signedIn: false }, result: frames(domain, mode === "rejected" ? "rejected" : humanStep) },
        { when: { prepared: true, signedIn: false }, result: frames(domain, humanStep) },
        { when: { step: 1 }, result: frames(provider, "identifier") },
        { when: { step: 2 }, result: frames(owner, "password") },
        { when: { signedIn: true }, result: frames(domain, "signed-in") },
        { result: frames(domain, "identifier") },
      ],
      "ox.web.browser.showPage": human ? [{ args: { pageId: "fixture-page" }, when: { prepared: true, presented: false }, result: { status: mode === "cancelled" ? "cancelled" : "completed" }, set: { presented: true, signedIn: !blocked } }] : [{ error: { code: "unexpected_handoff", message: "No human step is present.", recovery: "Inspect authentication without reopening sign-in." } }],
      "ox.user.choose": [{ result: mode === "choose-manual" ? "Sign in manually" : "Stop" }],
      "ox.web.browser.snapshot": [
        { when: { step: 3, signedIn: false }, result: state(domain, mode === "rejected" ? "rejected" : humanStep) },
        { when: { prepared: true, signedIn: false }, result: state(domain, humanStep) },
        { when: { step: 1 }, result: state(provider, "identifier") },
        { when: { step: 2 }, result: state(owner, "password") },
        { when: { signedIn: true }, result: state(domain, "signed-in") },
        { result: state(domain, "identifier") },
      ],
    } },
    checks: run => [
      readResource(run, "skills/authentication/SKILL.md"),
      { detail: "Presented required human step once on its owning page", passed: run.calls.filter(call => call.name === "ox.web.browser.showPage").length === (human ? 1 : 0) && run.calls.filter(call => call.name === "ox.web.browser.showPage").every(call => call.args.pageId === "fixture-page") },
      { detail: "Cancelled handoff stops dependent work", passed: mode !== "cancelled" || run.calls.slice(run.calls.findIndex(call => call.name === "ox.web.browser.showPage") + 1).every(call => !["ox.service.invoke", "ox.web.browser.showPage"].includes(call.name)) },
      { detail: "No repeated rejected credentials or unnecessary login", passed: run.calls.filter(call => call.name === "ox.service.invoke" && String(call.args.name).endsWith(":login")).length === (mode === "existing" ? 0 : federated ? 3 : manual ? 1 : 2) },
      { detail: "Manual account choice is honored", passed: mode !== "choose-manual" || run.calls.some(call => call.name === "ox.user.choose" && Array.isArray(call.args.options) && call.args.options.includes("Ada Fixture") && call.args.options.includes("Sign in manually")) && run.calls.filter(call => String(call.args.name).endsWith(":login")).every(call => !(call.args.input as Record<string, unknown> | undefined)?.account) },
      { detail: "Human steps and rejected credentials do not trigger service repair", passed: !human && mode !== "rejected" || !run.calls.some(call => call.name === "ox.fs.read" && call.args.path === "skills/evolve/SKILL.md" || ["ox.fs.write", "ox.fs.edit", "ox.service.validate"].includes(call.name)) },
      { detail: "Read authenticated fixture inbox", passed: blocked ? run.state.read === false : run.state.read === true && run.state.signedIn === true },
      { detail: "Reported the observed message subject", passed: blocked ? !run.answer.includes("Welcome to the SSR fixture") : run.answer.includes("Welcome to the SSR fixture") },
      { detail: "No failed fixture calls", passed: run.calls.every(call => !call.error) },
      { detail: "Verified fresh destination sessions", passed: blocked || run.calls.some((call, index) => call.args.name === `web:${domain}:listSessions` && Array.isArray(call.result) && call.result.length > 0 && run.calls.slice(index + 1).some(next => next.args.name === `web:${domain}:getInbox`)) },
      { detail: "Did not retrieve credentials in chat", passed: !run.calls.some(call => call.name === "ox.secret.get") },
    ],
  };
}
