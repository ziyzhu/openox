import { action, clear, cookies, count, counter, escape, findAccount, form, json, page, redirect, Sessions, setCookie, webService, type Site } from "./shared.ts";

const host = "ox-gql.localhost";
const sessions = new Sessions("gql_session");
const counters = counter();
const notes = new Map<string, Array<{ id: string; title: string }>>();
const note = { type: "object", additionalProperties: false, required: ["id", "title"], properties: { id: { type: "string" }, title: { type: "string" } } };

const signIn = (error = "") => page("Sign in", `<h1>Sign in</h1>${error ? `<p role="alert">${escape(error)}</p>` : ""}
  <form method="post" action="/login"><label>Email<input name="username" type="email" autocomplete="username"></label>
  <label>Password<input name="password" type="password" autocomplete="current-password"></label><button id="submit">Sign in</button></form>`);

export const gql: Site = {
  name: "gql",
  hosts: [host],
  counters,
  reset() { sessions.clear(); clear(counters); notes.clear(); },
  services: origin => [{
    manifest: webService(host, "GraphQL Fixture", origin(host), [
      action("listNotes", "List the signed-in account's notes.", {
        auth: true, output: { type: "object", additionalProperties: false, required: ["notes"], properties: { notes: { type: "array", items: note } } },
      }),
      action("addNote", "Create a note.", {
        auth: true, approval: true,
        input: { type: "object", additionalProperties: false, required: ["title"], properties: { title: { type: "string", minLength: 1 } } },
        output: note,
      }),
    ], { loginPath: "/login" }),
    actions: "gql.actions.js",
  }],
  async handle(request, url) {
    const account = sessions.account(request);
    const csrf = cookies(request).gql_csrf;
    const withCsrf = (response: Response) => {
      if (!csrf) response.headers.append("set-cookie", setCookie("gql_csrf", crypto.randomUUID(), { httpOnly: false, sameSite: "Strict" }));
      return response;
    };
    if (request.method === "GET" && url.pathname === "/") {
      return withCsrf(page("GraphQL Fixture", account ? `<span id="me">${escape(account.label)}</span>` : `<a id="sign-in" href="/login">Sign in</a>`));
    }
    if (request.method === "GET" && url.pathname === "/login") return withCsrf(account ? redirect("/") : signIn());
    if (request.method === "POST" && url.pathname === "/login") {
      count(counters, "passwordSubmissions");
      const fields = await form(request);
      const match = findAccount(fields.username ?? "");
      if (!match || match.password !== fields.password) {
        count(counters, "passwordRejections");
        return signIn("Wrong email or password.");
      }
      return redirect("/", { "set-cookie": setCookie("gql_session", sessions.create(match)) });
    }
    if (request.method === "POST" && url.pathname === "/graphql") {
      if (!csrf || request.headers.get("x-csrf-token") !== csrf) {
        count(counters, "csrfRejections");
        return json({ errors: [{ message: "CSRF token mismatch" }] }, 403);
      }
      const body = await request.json() as { operationName?: string; variables?: { title?: string } };
      count(counters, `graphql:${body.operationName}`);
      if (body.operationName === "Viewer") return json({ data: { viewer: account ? { id: account.id, name: account.label } : null } });
      if (!account) return json({ data: null, errors: [{ message: "UNAUTHENTICATED" }] });
      const owned = notes.get(account.id) ?? [{ id: "n1", title: "Seeded note" }];
      notes.set(account.id, owned);
      if (body.operationName === "Notes") return json({ data: { notes: owned } });
      if (body.operationName === "AddNote" && body.variables?.title) {
        const created = { id: `n${owned.length + 1}`, title: body.variables.title };
        owned.push(created);
        return json({ data: { addNote: created } });
      }
      return json({ errors: [{ message: "Unknown operation" }] }, 400);
    }
    return new Response("Not found", { status: 404 });
  },
};
