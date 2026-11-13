import { action, clear, count, counter, escape, findAccount, form, page, redirect, Sessions, setCookie, webService, type Site } from "./shared.ts";

const host = "ox-ssr.localhost";
const sessions = new Sessions("ssr_session");
const counters = counter();
const articles = [{ id: "a1", title: "Rendered on the server" }, { id: "a2", title: "Hydrated on the client" }];
const messages = [{ id: "m1", subject: "Welcome to the SSR fixture" }];

const identifier = (error = "") => page("Sign in", `<h1>Sign in</h1>${error ? `<p role="alert">${escape(error)}</p>` : ""}
  <form method="post" action="/login/identifier"><label>Email<input name="username" type="email" autocomplete="username"></label><button id="next">Next</button></form>`);

const password = (username: string, error = "") => page("Enter password", `<h1>Welcome</h1>${error ? `<p role="alert">${escape(error)}</p>` : ""}
  <form method="post" action="/login/password"><input name="username" autocomplete="username" value="${escape(username)}" readonly>
  <label>Password<input name="password" type="password" autocomplete="current-password"></label><button id="submit">Sign in</button></form>`);

export const ssr: Site = {
  name: "ssr",
  hosts: [host],
  counters,
  reset() { sessions.clear(); clear(counters); },
  services: origin => [{
    manifest: webService(host, "SSR Fixture", origin(host), [
      action("listArticles", "Read public articles from the page's hydration data.", {
        output: { type: "object", additionalProperties: false, required: ["articles"], properties: { articles: { type: "array", items: { type: "object", additionalProperties: false, required: ["id", "title"], properties: { id: { type: "string" }, title: { type: "string" } } } } } },
      }),
      action("getInbox", "Read the signed-in account's inbox.", {
        auth: true,
        output: { type: "object", additionalProperties: false, required: ["account", "messages"], properties: { account: { type: "string" }, messages: { type: "array", items: { type: "object", additionalProperties: false, required: ["id", "subject"], properties: { id: { type: "string" }, subject: { type: "string" } } } } } },
      }),
    ], { loginPath: "/login", extra: { auth: [{ type: "password" }] } }),
    actions: "ssr.actions.js",
  }],
  async handle(request, url) {
    const account = sessions.account(request);
    if (request.method === "GET" && url.pathname === "/") {
      count(counters, "home");
      const header = account
        ? `<a id="me" data-account="${account.id}" href="/inbox">${escape(account.label)}</a>`
        : `<a id="sign-in" href="/login">Sign in</a>`;
      return page("SSR Fixture", `<header>${header}</header><h1>Articles</h1><ul>${articles.map(item => `<li>${escape(item.title)}</li>`).join("")}</ul>`,
        `<script id="__NEXT_DATA__" type="application/json">${JSON.stringify({ props: { pageProps: { articles } } })}</script>`);
    }
    if (request.method === "GET" && url.pathname === "/login") return account ? redirect("/") : identifier();
    if (request.method === "POST" && url.pathname === "/login/identifier") {
      const fields = await form(request);
      return findAccount(fields.username ?? "") ? redirect(`/login/password?username=${encodeURIComponent(fields.username!.trim().toLowerCase())}`) : identifier("No fixture account uses that email.");
    }
    if (request.method === "GET" && url.pathname === "/login/password") return password(url.searchParams.get("username") ?? "");
    if (request.method === "POST" && url.pathname === "/login/password") {
      count(counters, "passwordSubmissions");
      const fields = await form(request);
      const match = findAccount(fields.username ?? "");
      if (!match || match.password !== fields.password) {
        count(counters, "passwordRejections");
        return password(fields.username ?? "", "Wrong password.");
      }
      return redirect("/", { "set-cookie": setCookie("ssr_session", sessions.create(match)) });
    }
    if (request.method === "GET" && url.pathname === "/inbox") {
      count(counters, "inbox");
      if (!account) return redirect("/login");
      return page("Inbox", `<h1 id="inbox" data-account="${account.id}">Inbox</h1><ul>${messages.map(item => `<li data-id="${item.id}">${escape(item.subject)}</li>`).join("")}</ul>`);
    }
    return new Response("Not found", { status: 404 });
  },
};
