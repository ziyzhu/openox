import { createHash } from "node:crypto";
import { action, clear, count, counter, favicon, json, redirect, type Site } from "./shared.ts";

const hosts = ["ox-api.localhost", "ox-mcp.localhost", "ox-provider.localhost"];
const counters = counter();
type Grant = { client: string; redirect: string; challenge: string; resource: string | null; host: string };
const codes = new Map<string, Grant>();
const access = new Map<string, string>();
const refresh = new Map<string, string>();
export const oauthControl = { rejectRequests: false, wrongState: false };
const digest = (value: string) => createHash("sha256").update(value).digest("base64url");

export const oauth: Site = {
  name: "oauth", hosts, counters,
  reset() {
    clear(counters); codes.clear(); access.clear(); refresh.clear();
    oauthControl.rejectRequests = false;
    oauthControl.wrongState = false;
  },
  services: origin => [{
    manifest: {
      kind: "api", domain: hosts[0]!, name: "OAuth API Fixture", faviconUrl: favicon, baseUrl: `${origin(hosts[0]!)}/`,
      auth: { type: "oauth2", flow: "authorizationCode", authorizationURL: `${origin(hosts[0]!)}/authorize`,
        tokenURL: `${origin(hosts[0]!)}/token`, clientID: "fixture-api", redirectURI: "openox://oauth/fixture", scopes: ["fixture"], pkce: "S256" },
      actions: [
        action("publicRead", "Read without credentials.", { output: { type: "object", properties: { public: { type: "boolean" } }, required: ["public"], additionalProperties: false } }),
        action("read", "Read with OAuth.", { auth: true, output: { type: "object", properties: { authenticated: { type: "boolean" } }, required: ["authenticated"], additionalProperties: false } }),
        action("write", "Submit a mutation once.", { auth: true, approval: true, output: { type: "object", properties: { authenticated: { type: "boolean" } }, required: ["authenticated"], additionalProperties: false } }),
      ],
    }, actions: "oauth-api.actions.js",
  }],
  async handle(request, url, origin) {
    const host = url.hostname;
    const base = origin(host);
    const bump = (name: string) => count(counters, `${host}:${name}`);
    const invalid = () => json({ error: "invalid_grant" }, 400);
    if (url.pathname === "/.well-known/oauth-protected-resource/mcp") {
      bump("resourceDiscovery");
      return json({ resource: `${base}/mcp`, authorization_servers: [base], scopes_supported: ["fixture"] });
    }
    if (url.pathname === "/.well-known/oauth-authorization-server") {
      bump("serverDiscovery");
      return json({ issuer: base, authorization_endpoint: `${base}/authorize`, token_endpoint: `${base}/token`,
        registration_endpoint: `${base}/register`, response_types_supported: ["code"], grant_types_supported: ["authorization_code", "refresh_token"],
        code_challenge_methods_supported: ["S256"], token_endpoint_auth_methods_supported: ["none"] });
    }
    if (url.pathname === "/register" && request.method === "POST") {
      const body = await request.json() as Record<string, unknown>;
      if (body.token_endpoint_auth_method !== "none" || !Array.isArray(body.redirect_uris)) return invalid();
      bump("registration");
      return json({ client_id: "fixture-mcp", redirect_uris: body.redirect_uris, token_endpoint_auth_method: "none" }, 201);
    }
    if (url.pathname === "/authorize") {
      bump("authorization");
      const query = url.searchParams;
      const client = query.get("client_id");
      const callback = query.get("redirect_uri");
      const challenge = query.get("code_challenge");
      const expected = host === hosts[0] ? "openox://oauth/fixture" : host === hosts[1] ? "http://localhost:49213/oauth/callback" : "openox://oauth/provider-fixture";
      if (!client || callback !== expected || !challenge || query.get("code_challenge_method") !== "S256" || query.get("response_type") !== "code" || !query.get("state")) return invalid();
      const code = crypto.randomUUID();
      codes.set(code, { host, client, redirect: callback, challenge, resource: query.get("resource") });
      const destination = new URL(callback);
      destination.searchParams.set("code", code);
      destination.searchParams.set("state", oauthControl.wrongState ? "wrong-state" : query.get("state")!);
      return redirect(destination.href);
    }
    if (url.pathname === "/token" && request.method === "POST") {
      const fields = request.headers.get("content-type")?.includes("application/json")
        ? await request.json() as Record<string, string> : Object.fromEntries(new URLSearchParams(await request.text()));
      if (fields.grant_type === "authorization_code") {
        bump("exchangeAttempts");
        const grant = codes.get(fields.code!);
        codes.delete(fields.code!);
        if (!grant || grant.host !== host || grant.client !== fields.client_id || grant.redirect !== fields.redirect_uri || grant.challenge !== digest(fields.code_verifier ?? "") || grant.resource !== (fields.resource ?? null)) return invalid();
        bump("exchange");
      } else if (fields.grant_type === "refresh_token") {
        bump("refreshAttempts");
        if (refresh.get(fields.refresh_token!) !== host) return invalid();
        refresh.delete(fields.refresh_token!);
        bump("refresh");
      } else return invalid();
      const token = crypto.randomUUID();
      const refreshToken = crypto.randomUUID();
      access.set(token, host); refresh.set(refreshToken, host);
      return json({ access_token: token, refresh_token: refreshToken, token_type: "Bearer", expires_in: 3600, scope: "fixture" });
    }
    const authorized = access.get((request.headers.get("authorization") ?? "").replace(/^Bearer /, "")) === host;
    if (url.pathname === "/public") {
      bump("public");
      if (request.headers.has("authorization")) bump("credentialLeak");
      return json({ public: true });
    }
    if (["/read", "/write", "/mcp", "/chat/completions"].includes(url.pathname)) {
      bump("requests");
      if (!authorized || oauthControl.rejectRequests) {
        bump("unauthorized");
        return json({ error: "unauthorized" }, 401, { "www-authenticate": `Bearer resource_metadata="${base}/.well-known/oauth-protected-resource/mcp", scope="fixture"` });
      }
      if (url.pathname === "/mcp") {
        if (request.method === "DELETE") return new Response(null, { status: 204 });
        const rpc = await request.json() as { id?: string | number; method: string; params?: { name: string } };
        if (rpc.id === undefined) return new Response(null, { status: 202 });
        let result: unknown;
        if (rpc.method === "initialize") result = { protocolVersion: "2025-11-25", serverInfo: { name: "OAuth Fixture", version: "1" }, capabilities: { tools: {} } };
        else if (rpc.method === "tools/list") result = { tools: [{ name: "read", inputSchema: { type: "object", properties: {}, additionalProperties: false } }] };
        else if (rpc.method === "tools/call" && rpc.params?.name === "read") {
          bump("dispatch"); result = { content: [{ type: "text", text: "OAuth fixture result" }], structuredContent: { authenticated: true } };
        } else return json({ jsonrpc: "2.0", id: rpc.id, error: { code: -32601, message: "Method not found" } });
        return json({ jsonrpc: "2.0", id: rpc.id, result });
      }
      bump("dispatch");
      if (url.pathname === "/chat/completions") {
        return new Response(`data: ${JSON.stringify({ choices: [{ delta: { content: "OAuth fixture result" }, finish_reason: null }] })}\n\ndata: ${JSON.stringify({ choices: [{ delta: {}, finish_reason: "stop" }], usage: { prompt_tokens: 2, completion_tokens: 3, total_tokens: 5 } })}\n\ndata: [DONE]\n\n`, { headers: { "content-type": "text/event-stream" } });
      }
      return json({ authenticated: true });
    }
    return new Response("Not found", { status: 404 });
  },
};
