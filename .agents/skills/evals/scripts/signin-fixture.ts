import standards from "../../../../packages/agent/src/functions/service/standard-actions.json";
import type { StubRule } from "../../../../packages/agent/evals/stubs";
import type { EvalCase } from "./types.ts";

const observed = "page" in standards.web.find(action => action.id === "login")!.outputSchema.properties!;
const domain = "ox-ssr.localhost";
const provider = "accounts.ox-suite.localhost";
const purpose = "Complete fixture sign-in";

function page(host: string, step: string) {
  const frame = { id: `${host}-${step}`, parentId: null, origin: `https://${host}`, isMainFrame: true, serviceID: `web:${host}`, attached: host === domain ? true : { $state: "providerAttached" } };
  const document = {
    headings: [step === "signed-in" ? "Inbox" : "Sign in"], messages: [],
    controls: step === "signed-in" ? [] : [{ type: step === "identifier" ? "email" : "password", label: step === "identifier" ? "Email" : "Password", disabled: false, invalid: false }],
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

export function signinFixture(mode: "password" | "provider" | "manual"): EvalCase {
  const federated = mode === "provider";
  const manual = mode === "manual";
  const owner = federated ? provider : domain;
  const auth = federated ? { type: "provider", service: `web:${provider}` } : { type: "password" };
  const service = (host: string) => ({ domain: host, name: "Sign-in Fixture", kind: "web", saved: true, attached: true, login: "unknown" });
  const sessions = [{ id: "ada", label: "Ada Fixture", url: `https://${domain}/` }];
  const inbox = { account: "ada", messages: [{ id: "m1", subject: "Welcome to the SSR fixture" }] };
  const inspection = (host: string) => ({
    ...service(host), standardActions: ["login", "listSessions"], auth: host === domain ? [auth] : [{ type: "password" }],
    secrets: manual ? [] : [{ key: "fixture-ada", displayName: "Ada Fixture", type: "account", ...observed ? { serviceID: `web:${owner}` } : {} }],
    actions: host === domain ? { getInbox: { description: "Read this account's inbox", inputSchema: { type: "object", properties: {}, additionalProperties: false }, outputSchema: { type: "object" }, requireAuth: true, requireApproval: false } } : {},
  });
  const invoke: StubRule[] = [
    { args: { name: `web:${domain}:listSessions` }, when: { signedIn: true }, result: sessions },
    { args: { name: `web:${domain}:listSessions` }, result: [] },
    { args: { name: `web:${domain}:getInbox` }, when: { signedIn: true }, result: inbox, set: { read: true } },
  ];
  if (manual) invoke.push({ args: { name: `web:${domain}:login` }, result: result(domain, "identifier"), set: { prepared: true } });
  else {
    if (federated) invoke.push({ args: { name: `web:${domain}:login`, input: { auth } }, when: { step: 0 }, result: result(provider, "identifier"), set: { step: 1 } });
    invoke.push(
      { args: { name: `web:${owner}:login`, input: { auth: { type: "password" }, account: { $secret: "fixture-ada" } } }, when: { step: federated ? 1 : 0 }, result: result(owner, "password"), set: { step: 2 } },
      { args: { name: `web:${owner}:login`, frameId: `${owner}-password`, input: { auth: { type: "password" }, account: { $secret: "fixture-ada" } } }, when: { step: 2 }, result: result(domain, "signed-in"), set: { step: 3, signedIn: true } },
    );
  }
  const controls = Array.from({ length: 12 }, (_, index) => ({ selector: `*:nth-child(1) > *:nth-child(2) > *:nth-child(${index + 1})`, kind: index < 2 ? "username" : "button" }));
  const steps = Array.from({ length: 24 }, (_, index) => ({ event: index % 2 ? "focus" : "click", origin: `https://${domain}`, mainFrame: true, route: "/login", controls }));
  const trace = { steps, truncated: false };
  const tracePath = "tmp/fixture-login-trace.txt";
  return {
    task: manual ? `Sign in manually to ${domain}, then tell me the subject of my inbox message.` : `Use my saved Ada Fixture login to sign in to ${domain}${federated ? " with its advertised account provider" : ""}, then tell me the subject of my inbox message.`,
    timeoutMs: 180_000,
    stubs: { state: { step: 0, signedIn: false, read: false }, files: { [tracePath]: JSON.stringify(trace) }, functions: {
      "ox.service.inspect": [domain, provider].map(host => { const { domain: _, name: _name, kind: _kind, saved: _saved, attached: _attached, login: _login, ...rest } = inspection(host); return { args: { domain: host }, result: { service: service(host), ...rest } }; }),
      "ox.service.invoke": invoke,
      "ox.web.browser.newPage": [{ result: { pageId: "fixture-page", mainFrameId: `${domain}-identifier` } }],
      "ox.web.browser.pages": [
        { when: { step: 1 }, result: listing(provider) },
        { when: { step: 2 }, result: listing(owner) },
        { result: listing(domain) },
      ],
      "ox.web.browser.frames": [
        { when: { step: 1 }, result: frames(provider, "identifier") },
        { when: { step: 2 }, result: frames(owner, "password") },
        { when: { signedIn: true }, result: frames(domain, "signed-in") },
        { result: frames(domain, "identifier") },
      ],
      "ox.web.browser.showPage": [{ args: { pageId: "fixture-page" }, when: { prepared: true }, result: { shown: true, status: "awaiting_user" }, set: { awaiting: true } }],
      "ox.user.choose": [{ result: "Ada Fixture" }],
      "ox.web.browser.snapshot": [
        { when: { step: 1 }, result: state(provider, "identifier") },
        { when: { step: 2 }, result: state(owner, "password") },
        { when: { signedIn: true }, result: state(domain, "signed-in") },
        { result: state(domain, "identifier") },
      ],
    } },
    ...manual ? { continuation: {
      task: `<user_interaction>\nDone: ${purpose}\n</user_interaction>\n<login_trace>\n${JSON.stringify(observed ? { stepCount: steps.length, origins: [`https://${domain}`], truncated: false, path: tracePath } : trace)}\n</login_trace>`,
      when: { awaiting: true }, state: { signedIn: true },
    } } : {},
    checks: run => [
      { detail: "Read authenticated fixture inbox", passed: run.state.read === true && run.state.signedIn === true },
      { detail: "Reported the observed message subject", passed: run.answer.includes("Welcome to the SSR fixture") },
      { detail: "No failed fixture calls", passed: run.calls.every(call => !call.error) },
      { detail: "Verified fresh destination sessions", passed: run.calls.some(call => call.args.name === `web:${domain}:listSessions` && Array.isArray(call.result) && call.result.length > 0) },
      { detail: "Did not retrieve credentials in chat", passed: !run.calls.some(call => call.name === "ox.secret.get") },
    ],
  };
}
