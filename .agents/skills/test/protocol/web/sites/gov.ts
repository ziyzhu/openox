import { action, clear, count, counter, escape, findAccount, form, json, page, redirect, Sessions, setCookie, webService, type Account, type Site } from "./shared.ts";

const govHost = "ox-gov.localhost";
const idpHost = "ox-govid.localhost";
const govSessions = new Sessions("gov_session");
const idpSessions = new Sessions("govid_session");
const codes = new Map<string, { account: Account; state: string }>();
const counters = counter();
const securityCode = "246810";

const hidden = (fields: Record<string, string>) => Object.entries(fields).map(([name, value]) => `<input type="hidden" name="${name}" value="${escape(value)}">`).join("");
const alert = (error: string) => error ? `<p role="alert">${escape(error)}</p>` : "";

const emailPage = (flow: Record<string, string>, error = "") => page("Gov ID", `<h1>Sign in</h1>${alert(error)}
  <form method="post" action="/signin/email">${hidden(flow)}<label>Email<input name="username" type="email" autocomplete="username"></label><button id="submit">Submit</button></form>`);

const passwordPage = (flow: Record<string, string>, error = "") => page("Gov ID", `<h1>Enter your password</h1>${alert(error)}
  <form method="post" action="/signin/password">${hidden(flow)}<label>Password<input name="password" type="password" autocomplete="current-password"></label><button id="submit">Submit</button></form>`);

const codePage = (flow: Record<string, string>, error = "") => page("Gov ID", `<h1>Verify your session</h1>${alert(error)}
  <form method="post" action="/signin/code">${hidden(flow)}<label>Security code<input name="code" inputmode="numeric" autocomplete="one-time-code"></label><button id="submit">Submit</button></form>`);

const flowFields = (fields: Record<string, string | undefined>) => ({ state: fields.state ?? "", redirect_uri: fields.redirect_uri ?? "", username: fields.username ?? "" });

export const gov: Site = {
  name: "gov",
  hosts: [govHost, idpHost],
  counters,
  reset() { govSessions.clear(); idpSessions.clear(); codes.clear(); clear(counters); },
  services: origin => [
    {
      manifest: webService(govHost, "Gov Account Fixture", origin(govHost), [
        action("getCases", "Read the signed-in account's cases.", {
          auth: true, output: { type: "object", additionalProperties: false, required: ["account", "cases"], properties: { account: { type: "string" }, cases: { type: "array", items: { type: "string" } } } },
        }),
      ], { loginPath: "/sign-in", extra: { auth: [{ type: "provider", service: `web:${idpHost}` }] } }),
      actions: "gov.actions.js",
    },
    {
      manifest: webService(idpHost, "Gov ID Fixture", origin(idpHost), [], { loginPath: "/" }),
      actions: "gov-id.actions.js",
    },
  ],
  async handle(request, url, origin) {
    if (url.hostname === govHost) {
      const account = govSessions.account(request);
      if (request.method === "GET" && url.pathname === "/") {
        if (!account) return redirect("/sign-in");
        return page("Gov Account", `<span id="me" data-account="${escape(account.username)}">${escape(account.username)}</span><ul id="cases"><li>IOE0000000001</li></ul>`);
      }
      if (request.method === "GET" && url.pathname === "/sign-in") {
        if (account) return redirect("/");
        return page("Gov Account", `<h1>Sign in to your account</h1><a id="sign-in-provider" href="/auth/start">Sign in with Gov ID</a>`);
      }
      if (request.method === "GET" && url.pathname === "/auth/start") {
        count(counters, "authStarts");
        const state = crypto.randomUUID();
        const authorize = `${origin(idpHost)}/authorize?state=${state}&redirect_uri=${encodeURIComponent(`${origin(govHost)}/callback`)}`;
        return redirect(authorize, { "set-cookie": setCookie("gov_state", state, { maxAge: 600 }) });
      }
      if (request.method === "GET" && url.pathname === "/callback") {
        const state = url.searchParams.get("state") ?? "";
        const grant = codes.get(url.searchParams.get("code") ?? "");
        const cookie = request.headers.get("cookie")?.match(/(?:^|;\s*)gov_state=([^;]+)/)?.[1];
        if (!grant || grant.state !== state || cookie !== state) {
          count(counters, "callbackRejections");
          return page("Gov Account", `<p role="alert">This sign-in link is invalid or expired.</p><a id="sign-in-provider" href="/auth/start">Sign in with Gov ID</a>`);
        }
        codes.delete(url.searchParams.get("code")!);
        count(counters, "callbacks");
        const headers = new Headers({ location: "/", "cache-control": "no-store" });
        headers.append("set-cookie", setCookie("gov_session", govSessions.create(grant.account)));
        headers.append("set-cookie", setCookie("gov_state", "", { maxAge: 0 }));
        return new Response(null, { status: 303, headers });
      }
      if (url.pathname === "/api/session") return json({ account: account ? { id: account.username, label: account.username } : null });
      if (url.pathname === "/api/cases") return account ? json({ account: account.username, cases: ["IOE0000000001"] }) : json({ error: "unauthenticated" }, 401);
    }
    if (url.hostname === idpHost) {
      const account = idpSessions.account(request);
      if (url.pathname === "/api/session") return json({ account: account ? { id: account.username, label: account.username } : null });
      if (request.method === "GET" && url.pathname === "/") {
        return page("Gov ID", account ? `<h1 id="signed-in">${escape(account.username)}</h1>` : `<a id="start" href="/authorize">Sign in</a>`);
      }
      if (request.method === "GET" && url.pathname === "/authorize") {
        count(counters, "authorizeRequests");
        const flow = flowFields({ state: url.searchParams.get("state") ?? "", redirect_uri: url.searchParams.get("redirect_uri") ?? "" });
        return account ? codePage({ ...flow, username: account.username }) : emailPage(flow);
      }
      if (request.method === "POST" && url.pathname === "/signin/email") {
        const fields = await form(request);
        if (!findAccount(fields.username ?? "")) return emailPage(flowFields(fields), "No account uses that email.");
        return passwordPage(flowFields({ ...fields, username: fields.username!.trim().toLowerCase() }));
      }
      if (request.method === "POST" && url.pathname === "/signin/password") {
        count(counters, "passwordSubmissions");
        const fields = await form(request);
        const match = findAccount(fields.username ?? "");
        if (!match || match.password !== fields.password) {
          count(counters, "passwordRejections");
          return passwordPage(flowFields(fields), "Wrong password.");
        }
        return new Response(codePage(flowFields(fields)).body, {
          headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "set-cookie": setCookie("govid_session", idpSessions.create(match), { sameSite: "None" }) },
        });
      }
      if (request.method === "POST" && url.pathname === "/signin/code") {
        count(counters, "codeSubmissions");
        const fields = await form(request);
        const match = account ?? findAccount(fields.username ?? "");
        if (!match || fields.code?.trim() !== securityCode) return codePage(flowFields(fields), "That code is not valid.");
        const redirectURI = fields.redirect_uri ?? "";
        if (!redirectURI.startsWith(origin(govHost))) return page("Gov ID", `<h1 id="signed-in">${escape(match.username)}</h1>`);
        const code = crypto.randomUUID();
        codes.set(code, { account: match, state: fields.state ?? "" });
        const target = `${redirectURI}?code=${encodeURIComponent(code)}&state=${encodeURIComponent(fields.state ?? "")}`;
        return page("Gov ID", `<p id="returning">Returning to Gov Account…</p><script>setTimeout(() => location.replace(${JSON.stringify(target)}), 2500);</script>`);
      }
    }
    return new Response("Not found", { status: 404 });
  },
};

export const govSecurityCode = securityCode;
