import { CONVERSATION_ACTION_ID, CONVERSATION_ACTION_SCHEMA, MODEL_ACTION_SCHEMAS } from "../../../../../../packages/protocol/src/model-actions.ts";
import { action, clear, count, counter, findAccount, json, page, Sessions, setCookie, webService, type Site } from "./shared.ts";

const host = "ox-chat.localhost";
const sessions = new Sessions("chat_session");
const counters = counter();
const models = [{ id: "fixture-fast", name: "Fixture Fast", delay: 20 }, { id: "fixture-slow", name: "Fixture Slow", delay: 400 }];

const app = `
const root = document.querySelector("#app");
const render = async () => {
  const { account } = await (await fetch("/api/session", { cache: "no-store" })).json();
  if (account) {
    root.innerHTML = '<header><span id="me"></span></header><main><select id="model"></select><p id="status">Ready</p></main>';
    root.querySelector("#me").textContent = account.label;
    root.querySelector("#me").dataset.account = account.id;
    return;
  }
  root.innerHTML = '<button id="sign-in">Sign in</button><dialog id="login"><form><p role="alert" hidden></p><label>Email<input id="username" type="email" autocomplete="username"></label><button id="continue" type="button">Continue</button></form></dialog>';
  root.querySelector("#sign-in").onclick = () => root.querySelector("#login").showModal();
  root.querySelector("#continue").onclick = () => {
    const form = root.querySelector("#login form");
    root.querySelector("#continue").remove();
    form.insertAdjacentHTML("beforeend", '<label>Password<input id="password" type="password" autocomplete="current-password"></label><button id="submit" type="button">Sign in</button>');
    form.querySelector("#submit").onclick = async () => {
      const response = await fetch("/api/login", { method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ username: form.querySelector("#username").value, password: form.querySelector("#password").value }) });
      if (response.ok) return render();
      const alert = form.querySelector("[role=alert]");
      alert.textContent = "Wrong password.";
      alert.hidden = false;
    };
  };
};
render();`;

function stream(text: string, delay: number): Response {
  const words = text.split(/(?<= )/);
  let timer: ReturnType<typeof setTimeout> | undefined;
  return new Response(new ReadableStream({
    start(controller) {
      const encoder = new TextEncoder();
      controller.enqueue(encoder.encode(`data: ${JSON.stringify({ conversation: crypto.randomUUID() })}\n\n`));
      const next = (index: number) => {
        if (index === words.length) {
          controller.enqueue(encoder.encode(`data: ${JSON.stringify({ done: true })}\n\n`));
          count(counters, "completedStreams");
          controller.close();
          return;
        }
        controller.enqueue(encoder.encode(`data: ${JSON.stringify({ text: words[index] })}\n\n`));
        timer = setTimeout(() => next(index + 1), delay);
      };
      next(0);
    },
    cancel() {
      clearTimeout(timer);
      count(counters, "cancelledStreams");
    },
  }), { headers: { "content-type": "text/event-stream", "cache-control": "no-store" } });
}

export const chat: Site = {
  name: "chat",
  hosts: [host],
  counters,
  reset() { sessions.clear(); clear(counters); },
  services: origin => [{
    manifest: webService(host, "Chat Fixture", origin(host), [
      action("listModels", "List website model choices.", { input: MODEL_ACTION_SCHEMAS.listModels!.inputSchema, output: MODEL_ACTION_SCHEMAS.listModels!.outputSchema }),
      action(CONVERSATION_ACTION_ID, "Submit, read, or cancel a website conversation.", { input: CONVERSATION_ACTION_SCHEMA.inputSchema, output: CONVERSATION_ACTION_SCHEMA.outputSchema, auth: true }),
    ], { loginPath: "/" }),
    actions: "chat.actions.js",
  }],
  async handle(request, url) {
    const account = sessions.account(request);
    if (request.method === "GET" && url.pathname === "/") return page("Chat Fixture", `<div id="app"></div><script>${app}</script>`);
    if (url.pathname === "/api/session") return json({ account: account ? { id: account.id, label: account.label } : null });
    if (url.pathname === "/api/models") return json({ models: models.map(({ id, name }) => ({ id, name })) });
    if (request.method === "POST" && url.pathname === "/api/login") {
      count(counters, "passwordSubmissions");
      const body = await request.json() as { username?: string; password?: string };
      const match = findAccount(body.username ?? "");
      if (!match || match.password !== body.password) {
        count(counters, "passwordRejections");
        return json({ error: "invalid" }, 401);
      }
      return json({ ok: true }, 200, { "set-cookie": setCookie("chat_session", sessions.create(match)) });
    }
    if (request.method === "POST" && url.pathname === "/api/generate") {
      if (!account) return json({ error: "unauthenticated" }, 401);
      const body = await request.json() as { model?: string; messages?: Array<{ role: string; text: string }> };
      const model = models.find(item => item.id === body.model);
      if (!model) return json({ error: "unknown model" }, 400);
      count(counters, "generations");
      const prompt = body.messages?.filter(message => message.role === "user").at(-1)?.text ?? "";
      return stream(`Echo from ${model.name}: ${prompt}`, model.delay);
    }
    return new Response("Not found", { status: 404 });
  },
};
