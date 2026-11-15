import { action, counter, clear, page, favicon, type Site } from "./shared.ts";

const hosts = ["ox-catalog.localhost", "ox-search.localhost", "ox-settings.localhost"];
const counters = counter();
const object = (properties: Record<string, unknown>) => ({ type: "object", properties, required: Object.keys(properties), additionalProperties: false });
const text = { type: "string" };
const number = { type: "number" };
const array = (items: unknown) => ({ type: "array", items });
const exerciseSchemas = [
  object({ names: array(text), featured: text, last: text }),
  object({ text, clicks: number }),
  object({ checked: { type: "boolean" }, changes: number, theme: text, biography: text }),
];
const boundarySchema = object({ failures: object(Object.fromEntries(["ambiguous", "hidden", "disabled", "missing", "obscured", "readOnly"].map(name => [name, text]))), dispatched: number });
const benchmarkSchema = object({ iterationsPerBatch: number, batches: number, millisecondsPerRead: object({ raw: array(number), locator: array(number) }) });
export const automationBodies = {
  "ox-catalog.localhost": `const rows = page.locator("[data-product]");
const names = await rows.allTextContents();
const featured = await rows.filter({hasText: "Featured"}).getByRole("button", {name: "Details", exact: true}).getAttribute("data-id");
return {names: names.map(value => value.trim()), featured, last: await rows.last().getAttribute("data-product")};`,
  "ox-search.localhost": `await page.getByLabel("Search query", {exact: true}).fill("locator fixture");
await page.getByRole("button", {name: "Search", exact: true}).click();
await page.getByTestId("results").waitFor({state: "visible"});
return {text: await page.getByTestId("results").innerText(), clicks: Number(document.body.dataset.clicks)};`,
  "ox-settings.localhost": `await page.getByLabel("Notifications", {exact: true}).check();
await page.getByLabel("Notifications", {exact: true}).check();
await page.getByRole("combobox", {name: "Theme", exact: true}).selectOption("dark");
await page.getByPlaceholder("Biography", {exact: true}).fill("Fixture profile");
return {checked: document.querySelector("#notifications").checked, changes: Number(document.body.dataset.changes), theme: document.querySelector("#theme").value, biography: document.querySelector("textarea").value};`,
};

export function automationActions(host: string) {
  return `window.ox.install(({action}) => {
  action("exercise", {async invoke() {
    const page = createEmbeddedAutomation();
    ${automationBodies[host as keyof typeof automationBodies]}
  }});
  action("boundaries", {async invoke() {
    const page = createEmbeddedAutomation({timeout: 100});
    const failures = {};
    for (const [name, operation] of Object.entries({
      ambiguous: () => page.locator("[data-duplicate]").click(),
      hidden: () => page.getByTestId("hidden").click({timeout: 0}),
      disabled: () => page.getByTestId("disabled").click({timeout: 0}),
      missing: () => page.getByTestId("missing").waitFor({timeout: 0}),
      obscured: () => page.getByTestId("obscured").click(),
      readOnly: () => page.getByTestId("readonly").fill("blocked"),
    })) {
      try {await operation(); failures[name] = "accepted";} catch (error) {failures[name] = error.message;}
    }
    return {failures, dispatched: Number(document.body.dataset.forbidden || 0)};
  }});
  action("benchmark", {async invoke() {
    const page = createEmbeddedAutomation();
    const samples = {raw: [], locator: []};
    for (let batch = 0; batch < 12; batch++) {
      for (const kind of batch % 2 ? ["raw", "locator"] : ["locator", "raw"]) {
        const start = performance.now();
        for (let i = 0; i < 100000; i++) {
          const text = kind === "raw" ? document.querySelector("[data-benchmark]").textContent : await page.locator("[data-benchmark]").textContent();
          if (text !== "Benchmark fixture") throw new Error("Benchmark output mismatch");
        }
        samples[kind].push((performance.now() - start) / 100000);
      }
    }
    return {iterationsPerBatch: 100000, batches: 12, millisecondsPerRead: samples};
  }});
});`;
}

const boundaries = `<section style="margin-top:32px"><button data-duplicate>Duplicate</button><button data-duplicate>Duplicate</button><button data-testid="hidden" hidden>Hidden</button><button data-testid="disabled" disabled>Disabled</button><input data-testid="readonly" readonly value="unchanged"><div style="position:relative"><button data-testid="obscured">Obscured</button><div style="position:absolute;inset:0;background:white">Overlay</div></div><span data-benchmark>Benchmark fixture</span></section>
<script>document.querySelectorAll('[data-duplicate], [data-testid="hidden"], [data-testid="disabled"], [data-testid="obscured"]').forEach(element => element.onclick = () => document.body.dataset.forbidden = String(Number(document.body.dataset.forbidden || 0) + 1));</script>`;

export const automation: Site = {
  name: "automation", hosts, counters,
  reset() { clear(counters); },
  services(origin) {
    return hosts.map(host => ({
      manifest: {
        domain: host, name: `Automation ${host.split(".")[0]}`, description: "Embedded automation fixture.", baseUrl: origin(host) + "/", faviconUrl: favicon,
        actions: ["exercise", "boundaries", "benchmark"].map(id => action(id, "Exercise local fixture automation.", {output: id === "exercise" ? exerciseSchemas[hosts.indexOf(host)] : id === "boundaries" ? boundarySchema : benchmarkSchema, approval: id === "exercise" && host !== hosts[0]})),
      },
      actions: "automation.actions.js",
    }));
  },
  handle(_request, url) {
    let body = "";
    if (url.hostname === hosts[0]) body = `<main><article data-product="one">Basic<button data-id="one">Details</button></article><article data-product="two">Featured<button data-id="two">Details</button></article><article data-product="three">Premium<button data-id="three">Details</button></article></main>`;
    if (url.hostname === hosts[1]) body = `<label for="query">Search query</label><input id="query"><button id="search">Search</button><p data-testid="results" hidden></p><script>document.querySelector('#search').onclick = () => {document.body.dataset.clicks = String(Number(document.body.dataset.clicks || 0) + 1); const value = document.querySelector('#query').value; setTimeout(() => {const result = document.querySelector('[data-testid="results"]'); result.textContent = 'Results for ' + value; result.hidden = false;}, 60);};</script>`;
    if (url.hostname === hosts[2]) body = `<label><input type="checkbox" id="notifications">Notifications</label><label for="theme">Theme</label><select id="theme"><option value="light">Light</option><option value="dark">Dark</option></select><textarea placeholder="Biography"></textarea><script>document.body.dataset.changes = '0'; document.querySelector('#notifications').onchange = () => document.body.dataset.changes = String(Number(document.body.dataset.changes) + 1);</script>`;
    return page("Automation fixture", body + boundaries);
  },
};
