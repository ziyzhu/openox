export const countWords = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"];
const countWord = (value: number) => countWords[value] ?? String(value);
export interface ExecuteGuidanceInput {
  catalog: string; variant?: "ox" | "portable"; timeoutSeconds: number; maxLines: number; maxBytes: number;
  maxFetches?: number; maxTransientAttachments?: number; canCancelLoops?: boolean;
}

export function executeGuidance(input: ExecuteGuidanceInput) {
  if (typeof input?.catalog !== "string" || ![input.timeoutSeconds, input.maxLines, input.maxBytes].every(value => Number.isSafeInteger(value) && value > 0)
    || ![input.maxFetches ?? 8, input.maxTransientAttachments ?? 4].every(value => Number.isSafeInteger(value) && value >= 0)) throw new Error("Invalid execution guidance facts");
  const variant = input.variant ?? "portable";
  if (variant !== "ox" && variant !== "portable") throw new Error(`Unknown execution guidance variant: ${variant}`);
  return [
    "Run JavaScript as an async function body. Top-level await and return work. Print model-visible results with console.log or return. Use only exposed capabilities; no shell, Node, or direct filesystem access.",
    input.catalog,
    variant === "ox"
      ? "The catalog lists built-in function descriptions; call examples are not complete contracts. Read a function's full input/output schemas before first use. Print unfamiliar functions' synchronous .help() in a separate execution, batching helpers such as console.log(ox.fs.read.help(), ox.schedule.list.help()), then call them in a later execution. Full access helper contracts returned by ox.service.inspect also satisfy this requirement; do not fetch the same help again. Operational calls require a short purpose; help and ox.provider.schema() do not. Use ox.fs for files. Browser runs hidden from the user. Inspect a service's applicable access contracts: requestAccess performs setup or user interaction; checkAccess reads type-specific evidence without prompting. Website setup acknowledges interaction only; discover sessions afterward, select the intended account/tenant and reuse that descriptor. Protected invocations revalidate it; do not add an access check before each action. API configuration is not server acceptance. Use ox.service.showPage for review, human verification or payment on a prepared service page. Never request credentials in chat, submit payment from preparation, or replay writes after handoff. For new web authentication, build and attach listSessions and executable login, then requestAccess before authenticated exploration. For obsolete contracts, read Evolve and repair from current website evidence while preserving unrelated actions and website data; never synthesize a session from a boolean detector. Reserve ox.web.browser.waitForUserInteraction for authoring-only human steps unsupported by standard handoffs, not authentication bootstrap or fulfillment."
      : "Inspect unfamiliar contracts through available help. Use only the owning host and Profile's exposed persistence and handoff functions.",
    `Batch independent reads with Promise.allSettled, chain dependent operations, and filter large results before printing. Serialize writes and approval-dependent calls. Await every call whose outcome matters; pending calls are cancelled when the script ends. Calls are real and not rolled back on failure. Preserve error code, message, and recovery with console.error(error) or an explicit return. Verify uncertain effects before retrying writes.`,
    `Each execution is self-contained; never store continuation state on globalThis. Return concise progress or persist it through an authorized file. Use bounded loops. The active execution limit is ${input.timeoutSeconds} seconds. ${input.canCancelLoops ? "The runtime supports interrupting JavaScript loops." : "Cancellation does not forcibly stop an infinite JavaScript loop."}`,
    variant === "ox"
      ? `Service actions and user handoffs do not consume active execution time. Each execution may fetch at most ${countWord(input.maxFetches ?? 8)} public resources and add at most ${countWord(input.maxTransientAttachments ?? 4)} transient attachments; presented files do not count toward that attachment limit.`
      : "",
    `Combined console and return output is limited to the last ${input.maxLines} lines or ${Math.floor(input.maxBytes / 1024)} KiB, whichever is reached first. A clipped preview is incomplete. ${variant === "ox" ? "Full output is saved in a read-only conversation-local /tmp file until the conversation unloads; inspect it with ox.fs.read or ox.fs.grep. File pagination is a separate limit." : "Use only exposed output-recovery contracts."}`,
  ].filter(Boolean).join("\n\n");
}
