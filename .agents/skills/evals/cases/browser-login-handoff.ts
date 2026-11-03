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
const accessInput = {
  type: "object",
  properties: { domain: { type: "string", const: domain }, purpose: { type: "string" }, pageUrl: { type: "string" } },
  required: ["purpose", "domain"],
  additionalProperties: false,
};
const acknowledged = { domain, kind: "web", completed: true, completion: "acknowledged" };
const evidence = (sessions: object[]) => ({ domain, kind: "web", evidence: "listSessions", sessions });

export default {
  task: `Open my eye doctor's patient portal at https://${domain}/login so I can log in.`,
  stubs: { state: { loginAcknowledged: false }, functions: {
    "ox.service.find": [{ result: [service] }],
    "ox.service.attach": [{ result: service }],
    "ox.service.listAttached": [{ result: [service] }],
    "ox.service.inspect": [{ result: { service, capabilitiesAvailable: true, access: {
      kind: "web",
      checkAccess: { function: "ox.service.checkAccess", inputSchema: accessInput, outputSchema: {
        type: "object", properties: { domain: { type: "string" }, kind: { const: "web" }, evidence: { const: "listSessions" }, sessions: { type: "array", items: descriptor } },
        required: ["domain", "kind", "evidence", "sessions"], additionalProperties: false,
      } },
      requestAccess: { function: "ox.service.requestAccess", inputSchema: { ...accessInput, properties: { ...accessInput.properties, input: empty } }, outputSchema: {
        type: "object", properties: { domain: { type: "string" }, kind: { const: "web" }, completed: { const: true }, completion: { const: "acknowledged" } },
        required: ["domain", "kind", "completed", "completion"], additionalProperties: false,
      } },
    }, actions: {} } }],
    "ox.service.requestAccess": [{ args: { domain }, result: acknowledged, set: { loginAcknowledged: true } }],
    "ox.service.checkAccess": [
      { args: { domain }, when: { loginAcknowledged: false }, result: evidence([]) },
      { args: { domain }, when: { loginAcknowledged: true }, result: evidence([{ id: "patient-account", label: "Patient account", url: `https://${domain}/` }]) },
    ],
  } },
  checks: run => [
    { detail: "Used the canonical access request", passed: succeeded(run, "ox.service.requestAccess").some(call => call.args.domain === domain) },
    { detail: "Discovered accounts after interaction acknowledgment", passed: run.calls.some((call, index) => call.name === "ox.service.checkAccess" && run.calls.slice(0, index).some(previous => previous.name === "ox.service.requestAccess")) },
    { detail: "Did not substitute generic Browser interaction for authentication", passed: !run.calls.some(call => call.name === "ox.web.browser.waitForUserInteraction") },
    { detail: "Did not request credential entry in chat", passed: !/send me (?:your )?(?:password|api key)|tell me (?:your )?password/i.test(run.answer) },
  ],
} satisfies EvalCase;
