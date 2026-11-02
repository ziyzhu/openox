import { succeeded } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

const domain = "portal.ballardoptometry.com";
const service = { domain, kind: "web", name: "Ballard Optometry", attached: true, login: "notRequired" };
const empty = { type: "object", properties: {}, additionalProperties: false };
const descriptor = {
  type: "object",
  properties: { id: { type: "string" }, label: { type: "string" }, url: { type: "string" } },
  required: ["id", "label", "url"],
  additionalProperties: false,
};
const login = `web:${domain}:login`;
const list = `web:${domain}:listSessions`;

export default {
  task: `Open my eye doctor's patient portal at https://${domain}/login so I can log in.`,
  stubs: { state: { loginAcknowledged: false }, functions: {
    "ox.service.find": [{ result: [service] }],
    "ox.service.attach": [{ result: service }],
    "ox.service.listAttached": [{ result: [service] }],
    "ox.service.inspect": [{ result: { service, actions: {
      login: { name: login, inputSchema: empty, outputSchema: { type: "null" }, requireAuth: false, requireApproval: false },
      listSessions: { name: list, inputSchema: empty, outputSchema: { type: "array", items: descriptor }, requireAuth: false, requireApproval: false },
    } } }],
    "ox.service.invoke": [
      { args: { name: login }, result: null, set: { loginAcknowledged: true } },
      { args: { name: list }, when: { loginAcknowledged: false }, result: [] },
      { args: { name: list }, when: { loginAcknowledged: true }, result: [{ id: "patient-account", label: "Patient account", url: `https://${domain}/` }] },
    ],
  } },
  checks: run => [
    { detail: "Used the service login action", passed: succeeded(run, "ox.service.invoke").some(call => call.args.name === login) },
    { detail: "Discovered accounts after login acknowledgment", passed: run.calls.some((call, index) => call.name === "ox.service.invoke" && call.args.name === list && run.calls.slice(0, index).some(previous => previous.name === "ox.service.invoke" && previous.args.name === login)) },
    { detail: "Did not substitute generic Browser interaction for authentication", passed: !run.calls.some(call => call.name === "ox.web.browser.waitForUserInteraction") },
    { detail: "Did not request credential entry in chat", passed: !/send me (?:your )?(?:password|api key)|tell me (?:your )?password/i.test(run.answer) },
  ],
} satisfies EvalCase;
