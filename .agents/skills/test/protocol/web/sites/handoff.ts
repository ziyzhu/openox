import { clear, count, counter, page, redirect, webService, type Site } from "./shared.ts";

const counters = counter();
const scenarios = ["control", "slow", "stream", "server", "client", "loop", "timeout", "cancel"];
const domain = (scenario: string) => `ox-handoff-${scenario}.localhost`;
const ready = () => page("Handoff ready", '<h1>Handoff ready</h1><label>Email<input id="fixture-email" autocomplete="username"></label><button id="fixture-continue">Continue</button>');

export const handoff: Site = {
  name: "handoff",
  hosts: scenarios.map(domain),
  counters,
  reset() { clear(counters); },
  services(origin) {
    return scenarios.map(scenario => ({ manifest: webService(domain(scenario), `Handoff ${scenario}`, origin(domain(scenario)), [], { loginPath: `/prepare?scenario=${scenario}` }), actions: "handoff.actions.js" }));
  },
  async handle(request, url) {
    const scenario = url.searchParams.get("scenario") || "control";
    const increment = (name: string) => count(counters, `${scenario}.${name}`);
    if (url.pathname === "/dispatch" && request.method === "POST") {
      increment("dispatches");
      return new Response("ok");
    }
    if (url.pathname === "/prepare" || url.pathname === "/") return page("Prepare handoff", "<h1>Prepare handoff</h1>");
    if (url.pathname === "/start") {
      increment("starts");
      if (["slow", "timeout", "cancel"].includes(scenario)) {
        await Bun.sleep(scenario === "slow" ? 8_000 : 22_000);
        increment("destinations");
        return ready();
      }
      if (scenario === "stream") {
        const html = await ready().text();
        const body = html.indexOf("<body>");
        return new Response(new ReadableStream({
          async start(controller) {
            controller.enqueue(new TextEncoder().encode(html.slice(0, body)));
            await Bun.sleep(8_000);
            increment("destinations");
            controller.enqueue(new TextEncoder().encode(html.slice(body)));
            controller.close();
          },
        }), { headers: { "content-type": "text/html", "cache-control": "no-store" } });
      }
      if (["server", "client", "loop"].includes(scenario)) return redirect(`/hop?scenario=${scenario}&step=0`);
      increment("destinations");
      return ready();
    }
    if (url.pathname === "/hop") {
      increment("hops");
      const step = Number(url.searchParams.get("step"));
      await Bun.sleep(250);
      if (scenario !== "loop" && step >= (scenario === "server" ? 12 : 8)) {
        increment("destinations");
        return ready();
      }
      const next = `/hop?scenario=${scenario}&step=${step + 1}`;
      if (scenario === "server") return redirect(next);
      return page("Redirecting", "", `<script>location.replace(${JSON.stringify(next)})</script>`);
    }
    return new Response("Not found", { status: 404 });
  },
};
