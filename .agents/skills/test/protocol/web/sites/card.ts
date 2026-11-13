import { action, clear, count, counter, escape, findAccount, form, json, page, redirect, Sessions, setCookie, webService, type Account, type Site } from "./shared.ts";

const cardHost = "ox-card.localhost";
const idpHost = "ox-idp.localhost";
const cardSessions = new Sessions("card_session");
const idpSessions = new Sessions("idp_session");
const codes = new Map<string, Account>();
const counters = counter();

const cardScript = (idp: string) => `
const IDP = ${JSON.stringify(idp)};
document.querySelector("#sign-in")?.addEventListener("click", () => {
  if (document.querySelector("iframe[name='idp-auth-widget']")) return;
  const frame = document.createElement("iframe");
  frame.name = "idp-auth-widget";
  frame.title = "Fixture ID sign-in";
  frame.src = IDP + "/widget?client=ox-card";
  frame.style = "width:100%;height:420px;border:0";
  document.body.append(frame);
});
addEventListener("message", async event => {
  if (event.origin !== IDP || event.data?.type !== "ox-idp-code") return;
  const response = await fetch("/api/exchange", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ code: event.data.code }) });
  if (response.ok) location.reload();
});`;

const widgetForm = (card: string) => page("Fixture ID", `<form id="credentials"><p role="alert" hidden></p>
  <label>Email<input name="username" type="email" autocomplete="username"></label>
  <label>Password<input name="password" type="password" autocomplete="current-password"></label><button id="submit">Continue</button></form>
  <script>
  document.querySelector("#credentials").addEventListener("submit", async event => {
    event.preventDefault();
    const fields = Object.fromEntries(new FormData(event.target));
    const response = await fetch("/widget/authorize", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(fields) });
    if (!response.ok) { const alert = document.querySelector("[role=alert]"); alert.textContent = "Wrong email or password."; alert.hidden = false; return; }
    window.top.postMessage({ type: "ox-idp-code", code: (await response.json()).code }, ${JSON.stringify(card)});
  });
  </script>`);

const idpSignIn = (error = "") => page("Fixture ID", `<h1>Fixture ID</h1>${error ? `<p role="alert">${escape(error)}</p>` : ""}
  <form method="post" action="/signin"><label>Email<input name="username" type="email" autocomplete="username"></label>
  <label>Password<input name="password" type="password" autocomplete="current-password"></label><button id="submit">Sign in</button></form>`);

function verify(username = "", password = ""): Account | undefined {
  count(counters, "passwordSubmissions");
  const match = findAccount(username);
  if (match && match.password === password) return match;
  count(counters, "passwordRejections");
}

export const card: Site = {
  name: "card",
  hosts: [cardHost, idpHost],
  counters,
  reset() { cardSessions.clear(); idpSessions.clear(); codes.clear(); clear(counters); },
  services: origin => [
    {
      manifest: webService(cardHost, "Card Fixture", origin(cardHost), [
        action("getBalance", "Read the signed-in account's balance.", {
          auth: true, output: { type: "object", additionalProperties: false, required: ["account", "balance"], properties: { account: { type: "string" }, balance: { type: "number" } } },
        }),
      ], { loginPath: "/", extra: { auth: [{ type: "provider", service: `web:${idpHost}` }] } }),
      actions: "card.actions.js",
    },
    {
      manifest: webService(idpHost, "Fixture ID", origin(idpHost), [], { loginPath: "/signin" }),
      actions: "card-idp.actions.js",
    },
  ],
  async handle(request, url, origin) {
    if (url.hostname === cardHost) {
      const account = cardSessions.account(request);
      if (request.method === "GET" && url.pathname === "/") {
        return page("Card Fixture", account
          ? `<span id="me" data-account="${account.id}">${escape(account.label)}</span><p id="balance">1234.5</p>`
          : `<button id="sign-in">Sign in with Fixture ID</button><script>${cardScript(origin(idpHost))}</script>`);
      }
      if (url.pathname === "/api/session") return json({ account: account ? { id: account.id, label: account.label } : null });
      if (url.pathname === "/api/balance") return account ? json({ account: account.id, balance: 1234.5 }) : json({ error: "unauthenticated" }, 401);
      if (request.method === "POST" && url.pathname === "/api/exchange") {
        const { code } = await request.json() as { code?: string };
        const match = code ? codes.get(code) : undefined;
        if (!match) return json({ error: "invalid code" }, 400);
        codes.delete(code!);
        count(counters, "exchanges");
        return json({ ok: true }, 200, { "set-cookie": setCookie("card_session", cardSessions.create(match)) });
      }
    }
    if (url.hostname === idpHost) {
      const account = idpSessions.account(request);
      if (request.method === "GET" && url.pathname === "/widget") {
        count(counters, "widget");
        return page("Fixture ID", `<h2>Fixture ID</h2><iframe id="credentials-frame" title="Fixture ID credentials" src="/widget/form" style="width:100%;height:320px;border:0"></iframe>`);
      }
      if (request.method === "GET" && url.pathname === "/widget/form") return widgetForm(origin(cardHost));
      if (request.method === "POST" && url.pathname === "/widget/authorize") {
        const body = await request.json() as { username?: string; password?: string };
        const match = verify(body.username, body.password);
        if (!match) return json({ error: "invalid" }, 401);
        const code = crypto.randomUUID();
        codes.set(code, match);
        return json({ code }, 200, { "set-cookie": setCookie("idp_session", idpSessions.create(match), { sameSite: "None" }) });
      }
      if (url.pathname === "/api/session") return json({ account: account ? { id: account.id, label: account.label } : null });
      if (request.method === "GET" && url.pathname === "/signin") {
        return account ? page("Fixture ID", `<h1 id="signed-in" data-account="${account.id}">${escape(account.label)}</h1>`) : idpSignIn();
      }
      if (request.method === "POST" && url.pathname === "/signin") {
        const fields = await form(request);
        const match = verify(fields.username, fields.password);
        if (!match) return idpSignIn("Wrong email or password.");
        return redirect("/signin", { "set-cookie": setCookie("idp_session", idpSessions.create(match), { sameSite: "None" }) });
      }
    }
    return new Response("Not found", { status: 404 });
  },
};
