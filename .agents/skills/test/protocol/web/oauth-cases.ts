import { strict as assert } from "node:assert";
import { elements } from "../../../setup/scripts/ios.ts";
import { attemptScript, invokeScript, type Case } from "./cases.ts";
import { wait, type Harness, type Responder } from "./harness.ts";
import { oauthControl } from "./sites/oauth.ts";

const approve: Responder = prompt => {
  if (!/fixture|ox-api\.localhost|ox-mcp\.localhost/i.test(prompt.prompt)) return undefined;
  if (prompt.options.includes("Approve")) return "Approve";
  return /login|sign in|authenticate|authorize/i.test(prompt.prompt) ? wait : undefined;
};

async function authenticate(h: Harness, script: string, provider?: string) {
  await h.begin(script);
  let finished = false;
  const result = h.idle(approve).then(snapshot => h.lastResult(snapshot)).finally(() => { finished = true; });
  const drive = (async () => {
    const tapped = new Set<string>();
    while (!finished) {
      const tree = elements(await h.ios.describe());
      const button = tree.find(element => element.AXLabel === "Continue" && element.type === "Button")
        ?? tree.find(element => provider && element.AXUniqueId === `conversation.modelKeyLogin.${provider}`);
      const key = button?.AXUniqueId || button?.AXLabel;
      if (button && key && !tapped.has(key)) {
        tapped.add(key);
        await h.ios.tap(button.AXUniqueId ? { id: button.AXUniqueId } : { label: button.AXLabel! }, { stable: 300 });
      }
      await Bun.sleep(300);
    }
  })();
  try {
    const [value] = await Promise.all([result, drive]);
    return value;
  } finally { finished = true; }
}

export const oauthCases: Case[] = [
  {
    name: "popup-provider-hop", site: "popup",
    async run(h) {
      const initial = await h.turn(invokeScript("web:ox-popup.localhost:login", { auth: { type: "provider", service: "web:ox-popup-idp.localhost" } }));
      assert.equal(initial.authentication, "unverified");
      let state: any;
      for (let attempt = 0; attempt < 30; attempt++) {
        state = await h.turn('return await ox.web.browser.getPageState({ service: "ox-popup.localhost", purpose: "Inspect popup navigation" });');
        if (state.frames.some((frame: any) => frame.isMainFrame && frame.serviceID === "web:ox-popup-idp.localhost")) break;
        await Bun.sleep(300);
      }
      const frame = state.frames.find((frame: any) => frame.isMainFrame && frame.serviceID === "web:ox-popup-idp.localhost");
      assert.ok(frame, "target=_blank did not preserve an inspectable provider page");
      assert.equal(h.site("popup").counters.authorization, 1);
      assert.deepEqual(await h.turn(invokeScript("web:ox-popup-idp.localhost:login", { auth: { type: "password" } }, { frameId: frame.id })), { interaction: "automatic", authentication: "unverified" });
      let sessions: any[] = [];
      for (let attempt = 0; attempt < 20 && !sessions.length; attempt++) {
        await Bun.sleep(300);
        sessions = await h.turn(invokeScript("web:ox-popup.localhost:listSessions"));
      }
      assert.deepEqual(sessions.map(session => session.id), ["ada"]);
      assert.equal(h.site("popup").counters.callback, 1);
      return "target=_blank used the preserved page; provider callback dispatched once and destination session verified; window.opener is not covered";
    },
  },
  {
    name: "api-oauth-state-rejection", site: "oauth",
    async run(h) {
      assert.deepEqual(await h.turn(invokeScript("api:ox-api.localhost:publicRead")), { public: true });
      assert.equal(h.site("oauth").counters["ox-api.localhost:credentialLeak"] ?? 0, 0);
      const before = await h.turn(attemptScript("api:ox-api.localhost:read"));
      assert.ok(before.error);
      assert.equal(h.site("oauth").counters["ox-api.localhost:requests"] ?? 0, 0);
      oauthControl.wrongState = true;
      try {
        const rejected = await authenticate(h, attemptScript("api:ox-api.localhost:configureCredentials")) as { error?: string };
        assert.ok(rejected.error, "wrong-state callback was accepted");
        assert.equal(h.site("oauth").counters["ox-api.localhost:authorization"], 1);
        assert.equal(h.site("oauth").counters["ox-api.localhost:exchangeAttempts"] ?? 0, 0);
        assert.ok((await h.turn(attemptScript("api:ox-api.localhost:read"))).error);
      } finally { oauthControl.wrongState = false; }
      return "native API OAuth rejected mismatched state before token exchange; unauthenticated actions did not dispatch and public reads leaked no credentials";
    },
  },
  {
    name: "mcp-oauth-discovery", site: "oauth",
    async run(h) {
      const endpoint = `${h.fixtures.origin("ox-mcp.localhost")}/mcp`;
      const created = await h.turn(`return await ox.service.create({ purpose: "Create OAuth fixture", kind: "mcp", name: "OAuth MCP Fixture", endpoint: ${JSON.stringify(endpoint)} });`, approve);
      const domain = created.domain;
      assert.ok(domain);
      try {
        await authenticate(h, invokeScript(`mcp:${domain}:authorize`));
        const result = await h.turn(invokeScript(`mcp:${domain}:read`), approve);
        assert.deepEqual(result, { authenticated: true });
        const counters = h.site("oauth").counters;
        for (const name of ["resourceDiscovery", "serverDiscovery", "registration", "authorization", "exchange", "dispatch"]) assert.ok(counters[`ox-mcp.localhost:${name}`], `missing MCP ${name}`);
        assert.equal(counters["ox-mcp.localhost:exchange"], 1);
        assert.equal(counters["ox-mcp.localhost:dispatch"], 1);
        oauthControl.rejectRequests = true;
        assert.ok((await h.turn(attemptScript(`mcp:${domain}:read`), approve)).error);
        assert.equal(counters["ox-mcp.localhost:dispatch"], 1, "unauthorized tool call was replayed");
        return "native MCP OAuth discovered metadata, dynamically registered, exchanged PKCE code and invoked one tool; rejected calls did not dispatch";
      } finally {
        oauthControl.rejectRequests = false;
        await h.turn(`return await ox.service.delete({ purpose: "Remove OAuth fixture", domain: ${JSON.stringify(domain)} });`, approve);
      }
    },
  },
  {
    name: "provider-oauth-generation", site: "oauth",
    async run(h) {
      const id = "oauth-protocol-fixture";
      const base = h.fixtures.origin("ox-provider.localhost");
      const provider = { id, name: "OAuth Provider Fixture", api: "openai-chat-completions", url: base,
        auth: { kind: "oauth", flow: "authorization-code", clientID: "fixture-provider", authorizeURL: `${base}/authorize`, tokenURL: `${base}/token`, redirectURI: "openox://oauth/provider-fixture", scopes: ["fixture"] },
        models: [{ id: "fixture", name: "Fixture", contextTokens: 4096, outputTokens: 128, input: ["text"], output: ["text"] }] };
      await h.turn(`return await ox.provider.save({ purpose: "Save OAuth fixture", provider: ${JSON.stringify(provider)} });`, approve);
      try {
        const authenticated = await authenticate(h, `return await ox.provider.authenticate({ purpose: "Authenticate OAuth fixture", id: "${id}" });`, id) as { status: string };
        assert.equal(authenticated.status, "authenticated");
        const result = await h.turn(`return await ox.provider.generate({ purpose: "Verify OAuth inference", id: "${id}", model: "fixture", messages: [{ role: "user", content: "Fixture request" }], maxOutputTokens: 32 });`, approve);
        assert.equal(result.text, "OAuth fixture result");
        assert.equal(h.site("oauth").counters["ox-provider.localhost:exchange"], 1);
        assert.equal(h.site("oauth").counters["ox-provider.localhost:dispatch"], 1);
        await h.turn(`return await ox.provider.deauthenticate({ purpose: "Clear fixture credentials", id: "${id}" });`, approve);
        return "native model-provider OAuth exchanged a PKCE code, authenticated streaming inference and cleared credentials";
      } finally {
        await h.turn(`return await ox.provider.delete({ purpose: "Remove OAuth fixture", id: "${id}" });`, approve);
      }
    },
  },
];
