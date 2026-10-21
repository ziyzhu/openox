import { mentions, succeeded } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

const search = "web:mail.google.com:searchMessages";

export default {
  task: "Find the email from Dana about the Q3 budget in my Gmail.",
  attached: [{ domain: "mail.google.com", description: "Gmail", signIn: "signedIn" }],
  stubs: { functions: {
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
    "ox.service.invoke": [{ args: { name: search }, result: { messages: [] } }],
    "ox.web.browser.navigate": [{ result: { url: { $arg: "url" } } }],
    "ox.web.browser.getPageInfo": [{ result: { url: "https://mail.google.com/mail/u/0/#search/dana+q3+budget", title: "Search results - Gmail", estimatedProgress: 1, isLoading: false, hasOnlySecureContent: true, isBlockedByScreenTime: false, fullscreenState: "notInFullscreen" } }],
    "ox.web.browser.executeScript": [{ result: { text: "Dana Kim — Q3 budget review: final numbers — Oct 14\nDana Kim — Re: Q3 budget review: final numbers — Oct 15" } }],
  } },
  timeoutMs: 180_000,
  checks: run => {
    const first = run.calls.findIndex(call => call.name === "ox.service.invoke" && !call.error);
    const later = run.calls.slice(first + 1);
    return [
      { detail: "Searched with the attached Gmail service", passed: succeeded(run, "ox.service.invoke").length > 0 },
      { detail: "Cross-checked the empty result with Browser tools or another query", passed: first >= 0 && later.some(call => call.name.startsWith("ox.web.browser.") || call.name === "ox.service.invoke") },
      mentions(run, "Q3 budget review"),
      { detail: "Did not hand off to the user while already signed in", passed: !run.calls.some(call => call.name === "ox.web.browser.waitForUserInteraction") },
    ];
  },
} satisfies EvalCase;
