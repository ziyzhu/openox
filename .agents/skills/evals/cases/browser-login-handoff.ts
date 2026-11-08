import { succeeded } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

const domain = "portal.ballardoptometry.com";
const service = { domain, kind: "web", name: "Ballard Optometry", attached: true, saved: true, login: "notRequired" };
const login = `web:${domain}:login`;
const listSessions = `web:${domain}:listSessions`;

export default {
  task: `Open my eye doctor's patient portal at https://${domain}/login so I can log in.`,
  stubs: { state: { loginAcknowledged: false }, functions: {
    "ox.service.attach": [{ result: service }],
    "ox.service.listAttached": [{ result: [service] }],
    "ox.service.inspect": [{ result: { service, standardActions: ["listSessions", "login"], actions: {} } }],
    "ox.service.invoke": [
      { args: { name: login }, result: null, set: { loginAcknowledged: true } },
      { args: { name: listSessions }, when: { loginAcknowledged: false }, result: [] },
      { args: { name: listSessions }, when: { loginAcknowledged: true }, result: [{ id: "patient-account", label: "Patient account", url: `https://${domain}/` }] },
    ],
  } },
  checks: run => [
    { detail: "Used the standard website login action", passed: succeeded(run, "ox.service.invoke").some(call => call.args.name === login) },
    { detail: "Discovered accounts after interaction acknowledgment", passed: run.calls.some((call, index) => call.name === "ox.service.invoke" && call.args.name === listSessions && run.calls.slice(0, index).some(previous => previous.name === "ox.service.invoke" && previous.args.name === login)) },
    { detail: "Did not substitute generic Browser interaction for authentication", passed: !run.calls.some(call => call.name === "ox.web.browser.showPage" && call.args.waitForUserInteraction === true) },
    { detail: "Did not request credential entry in chat", passed: !/send me (?:your )?(?:password|api key)|tell me (?:your )?password/i.test(run.answer) },
  ],
} satisfies EvalCase;
