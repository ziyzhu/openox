import { mentions, succeeded } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

const search = "web:mail.google.com:searchMessages";

export default {
  task: "Find the email from Dana about the Q3 budget in my Gmail.",
  attached: [{ domain: "mail.google.com", description: "Gmail", signIn: "signedIn" }],
  stubs: { state: { searched: false }, functions: {
    "ox.service.listAttached": [{ result: [{ domain: "mail.google.com", kind: "web", name: "Gmail", attached: true }] }],
    "ox.service.inspect": [{ result: {
      service: { domain: "mail.google.com", kind: "web", name: "Gmail", attached: true, signIn: "signedIn" },
      actions: { searchMessages: {
        name: search,
        description: "Search the signed-in mailbox with Gmail search syntax.",
        inputSchema: { type: "object", properties: { query: { type: "string" } }, required: ["query"] },
        outputSchema: { type: "object", properties: { messages: { type: "array", items: { type: "object", properties: { from: { type: "string" }, subject: { type: "string" }, date: { type: "string" } } } } } },
      } },
    } }],
    "ox.service.invoke": [
      { args: { name: search }, when: { searched: false }, result: { messages: [] }, set: { searched: true } },
      { args: { name: search }, when: { searched: true }, result: { messages: [{ from: "Dana Kim", subject: "Q3 budget review", date: "2026-10-14" }] } },
    ],
  } },
  timeoutMs: 180_000,
  checks: run => {
    const calls = succeeded(run, "ox.service.invoke").filter(call => call.args.name === search);
    return [
      { detail: "Cross-checked the empty result with a different service query", passed: calls.length >= 2 && calls.slice(1).some(call => JSON.stringify(call.args.input) !== JSON.stringify(calls[0]!.args.input)) },
      mentions(run, "Q3 budget review"),
      { detail: "Did not use Browser as a fulfillment fallback", passed: !run.calls.some(call => call.name.startsWith("ox.web.browser.")) },
    ];
  },
} satisfies EvalCase;
