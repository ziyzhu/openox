import { action, clear, count, counter, escape, findAccount, form, json, page, redirect, Sessions, setCookie, webService, type Site } from "./shared.ts";

const site = "ox-suite.localhost";
const accountsHost = `accounts.${site}`;
const mailHost = `mail.${site}`;
const sessions = new Sessions("suite_session");
const counters = counter();

const hidden = (name: string, value: string) => `<input type="hidden" name="${name}" value="${escape(value)}">`;

const identifier = (next: string, error = "") => page("Suite Accounts", `<h1>Sign in</h1>${error ? `<p role="alert">${escape(error)}</p>` : ""}
  <form method="post" action="/signin/identifier">${hidden("continue", next)}<label>Email<input name="username" type="email" autocomplete="username"></label><button id="next">Next</button></form>`);

const password = (username: string, next: string, error = "") => page("Suite Accounts", `<h1>Welcome</h1>${error ? `<p role="alert">${escape(error)}</p>` : ""}
  <form method="post" action="/signin/password">${hidden("continue", next)}<input name="username" autocomplete="username" value="${escape(username)}" readonly>
  <label>Password<input name="password" type="password" autocomplete="current-password"></label><button id="next">Next</button></form>`);

const safeContinue = (value: string | undefined | null) => {
  try { return value && new URL(value).hostname.endsWith(`.${site}`) ? value : ""; } catch { return ""; }
};

export const suite: Site = {
  name: "suite",
  hosts: [accountsHost, mailHost],
  counters,
  reset() { sessions.clear(); clear(counters); },
  services: origin => [
    {
      manifest: webService(accountsHost, "Suite Accounts Fixture", origin(accountsHost), [], { loginPath: "/signin" }),
      actions: "suite-accounts.actions.js",
    },
    {
      manifest: webService(mailHost, "Suite Mail Fixture", origin(mailHost), [
        action("getInbox", "Read the signed-in account's inbox.", {
          auth: true,
          output: { type: "object", additionalProperties: false, required: ["account", "messages"], properties: { account: { type: "string" }, messages: { type: "array", items: { type: "string" } } } },
        }),
      ], { loginPath: "/", extra: { auth: [{ type: "provider", service: `web:${accountsHost}` }] } }),
      actions: "suite-mail.actions.js",
    },
  ],
  async handle(request, url, origin) {
    const account = sessions.account(request);
    if (url.hostname === accountsHost) {
      if (request.method === "GET" && url.pathname === "/ListAccounts") return json({ accounts: account ? [{ id: account.id, label: account.label }] : [] });
      if (request.method === "GET" && url.pathname === "/signin") {
        const next = safeContinue(url.searchParams.get("continue"));
        if (account && next) return redirect(next);
        if (account) return page("Suite Accounts", `<h1 id="signed-in" data-account="${account.id}">${escape(account.label)}</h1>`);
        return identifier(next);
      }
      if (request.method === "POST" && url.pathname === "/signin/identifier") {
        const fields = await form(request);
        if (!findAccount(fields.username ?? "")) return identifier(fields.continue ?? "", "No fixture account uses that email.");
        return redirect(`/signin/password?username=${encodeURIComponent(fields.username!.trim().toLowerCase())}&continue=${encodeURIComponent(fields.continue ?? "")}`);
      }
      if (request.method === "GET" && url.pathname === "/signin/password") return password(url.searchParams.get("username") ?? "", url.searchParams.get("continue") ?? "");
      if (request.method === "POST" && url.pathname === "/signin/password") {
        count(counters, "passwordSubmissions");
        const fields = await form(request);
        const match = findAccount(fields.username ?? "");
        if (!match || match.password !== fields.password) {
          count(counters, "passwordRejections");
          return password(fields.username ?? "", fields.continue ?? "", "Wrong password.");
        }
        return redirect(safeContinue(fields.continue) || "/signin", { "set-cookie": setCookie("suite_session", sessions.create(match), { domain: site }) });
      }
    }
    if (url.hostname === mailHost) {
      if (request.method === "GET" && url.pathname === "/api/accounts") return json({ accounts: account ? [{ id: account.id, label: account.label }] : [] });
      if (request.method === "GET" && url.pathname === "/") {
        count(counters, "mailHome");
        if (!account) {
          const signIn = `${origin(accountsHost)}/signin?continue=${encodeURIComponent(`${origin(mailHost)}/`)}`;
          return page("Suite Mail", `<a id="sign-in" href="${escape(signIn)}">Sign in</a>`);
        }
        return page("Suite Mail", `<span id="me" data-account="${account.id}">${escape(account.label)}</span><ul id="inbox"><li>Welcome to Suite Mail</li></ul>`);
      }
    }
    return new Response("Not found", { status: 404 });
  },
};
