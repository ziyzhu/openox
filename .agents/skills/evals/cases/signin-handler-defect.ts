import { signinFixture } from "../scripts/signin-fixture.ts";
import { readResource } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

const domain = "ox-ssr.localhost";
const directory = `repositories/local/web/${domain}`;
const source = `${directory}/actions.js`;
const base = signinFixture("manual");
const functions = base.stubs!.functions!;
const observation = functions["ox.web.browser.snapshot"]!.at(-1)!.result as { document: { controls: unknown[] } };
observation.document.controls.push({ id: "continue-sign-in", name: null, role: "button", label: "Continue", type: "submit", disabled: false, required: false, invalid: false });

export default {
  task: `The previous automatic login to ${domain} failed before any credentials were submitted: the Local handler still clicks #old-sign-in, but the current page uses #continue-sign-in. Repair that confirmed selector defect using the live page and Local source. Preserve the page and existing sessions. Do not submit credentials or run another automatic login to test it.`,
  stubs: {
    ...base.stubs,
    files: {
      "repositories/local/repository.json": JSON.stringify({ name: "Local", services: [`web:${domain}`] }),
      [`${directory}/service.json`]: JSON.stringify({ domain, name: "Sign-in Fixture", kind: "web", baseUrl: `https://${domain}/login`, faviconUrl: `https://${domain}/favicon.png`, auth: [{ type: "password" }], actions: [
        { id: "login", label: "Sign in", description: "Prepare sign-in", inputSchema: { type: "object", properties: { auth: { type: "object" }, account: { type: "object" } }, additionalProperties: false }, outputSchema: { type: "null" }, requireAuth: false, requireApproval: false },
        { id: "listSessions", label: "Accounts", description: "Discover accounts", inputSchema: { type: "object", properties: {}, additionalProperties: false }, outputSchema: { type: "array", items: { type: "object" } }, requireAuth: false, requireApproval: false },
      ] }),
      [source]: 'window.ox.install(({ action }) => { action("login", { async invoke() { const button = document.querySelector("#old-sign-in"); if (!button) throw new Error("Sign-in button missing"); button.click(); return null; } }); action("listSessions", { async invoke() { return []; } }); });',
    },
    functions: {
      ...functions,
      "ox.service.validate": [{ args: { domain }, result: { domain, valid: true } }],
    },
  },
  checks: async run => [
    readResource(run, "skills/authentication/SKILL.md"),
    readResource(run, "skills/evolve/SKILL.md"),
    readResource(run, "skills/evolve/references/web-authentication.md"),
    { detail: "Repaired the selector in Local source", passed: (await run.read(source))?.includes("#continue-sign-in") === true && !(await run.read(source))?.includes("#old-sign-in") },
    { detail: "Validated after repairing source", passed: run.calls.some((call, index) => call.name === "ox.service.validate" && !call.error && run.calls.slice(0, index).some(previous => ["ox.fs.edit", "ox.fs.write"].includes(previous.name) && previous.args.path === source)) },
    { detail: "No login replay or user handoff as a substitute for repair", passed: !run.calls.some(call => call.name === "ox.service.invoke" && String(call.args.name).endsWith(":login") || call.name === "ox.web.browser.showPage") },
    { detail: "No failed fixture calls", passed: run.calls.every(call => !call.error) },
  ],
} satisfies EvalCase;
