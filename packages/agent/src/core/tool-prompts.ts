import fsContracts from "../functions/fs/contracts.json";
import serviceContracts from "../functions/service/contracts.json";
import webContracts from "../functions/web/contracts.json";

const commonContracts = {
  "ox.fs.read": fsContracts["ox.fs.read"],
  "ox.fs.edit": fsContracts["ox.fs.edit"],
  "ox.fs.write": fsContracts["ox.fs.write"],
  "ox.web.search": webContracts["ox.web.search"],
  "ox.web.fetch": webContracts["ox.web.fetch"],
  "ox.service.attach": serviceContracts["ox.service.attach"],
  "ox.service.inspect": serviceContracts["ox.service.inspect"],
  "ox.service.invoke": serviceContracts["ox.service.invoke"],
};

export const countWords = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"];
const countWord = (value: number) => countWords[value] ?? String(value);
export interface ExecuteGuidanceInput {
  catalog: string; timeoutSeconds: number; maxLines: number; maxBytes: number;
  maxFetches?: number; maxTransientAttachments?: number; canCancelLoops?: boolean;
}

export function executeGuidance(input: ExecuteGuidanceInput) {
  if (typeof input?.catalog !== "string" || ![input.timeoutSeconds, input.maxLines, input.maxBytes].every(value => Number.isSafeInteger(value) && value > 0)
    || ![input.maxFetches ?? 8, input.maxTransientAttachments ?? 4].every(value => Number.isSafeInteger(value) && value >= 0)) throw new Error("Invalid execution guidance facts");
  return [
    "Run JavaScript as an async function body. Top-level await and return work. Print model-visible results with console.log or return. Use only exposed capabilities; no shell, Node, or direct filesystem access.",
    input.catalog,
    "The catalog lists built-in function descriptions; call examples are not complete contracts. Complete contracts for common functions follow below and may be used immediately without .help(). For other functions, read their full input/output schemas before first use: print unfamiliar functions' synchronous .help() in a separate execution, batch needed helpers, then call them in a later execution. Contracts already supplied here or by ox.service.inspect satisfy this requirement; do not fetch unchanged contracts again. Operational calls require a short purpose; help and ox.provider.schema() do not. Use ox.fs for files.",
    "Complete built-in contracts:\n" + JSON.stringify(commonContracts),
    "Inspect applicable service action and access contracts before use. Browser runs hidden from the user and is for service authoring, not fulfillment.",
    "Use service handoffs for login, review, human verification, and payment. Never request credentials in chat, submit payment from preparation, or replay writes after handoff.",
    `Batch independent reads with Promise.allSettled, chain predictable dependent operations in the same execution, and filter large results before printing. For example, attach then inspect a service together; after coherent source edits, validate then reload, stopping on failure. Return to the model when new evidence requires a decision, not between already-determined steps. Serialize writes and approval-dependent calls. Await every call whose outcome matters; pending calls are cancelled when the script ends. Calls are real and not rolled back on failure. Preserve error code, message, and recovery with console.error(error) or an explicit return. Verify uncertain effects before retrying writes.`,
    `Each execution is self-contained; never store continuation state on globalThis. Return concise progress or persist it through an authorized file. Use bounded loops. The active execution limit is ${input.timeoutSeconds} seconds. ${input.canCancelLoops ? "The runtime supports interrupting JavaScript loops." : "Cancellation does not forcibly stop an infinite JavaScript loop."}`,
    `Service actions and user handoffs do not consume active execution time. Each execution may fetch at most ${countWord(input.maxFetches ?? 8)} public resources and add at most ${countWord(input.maxTransientAttachments ?? 4)} transient attachments; presented files do not count toward that attachment limit.`,
    `Combined console and return output is limited to the last ${input.maxLines} lines or ${Math.floor(input.maxBytes / 1024)} KiB, whichever is reached first. A clipped preview is incomplete. Full output is saved in a read-only conversation-local /tmp file until the conversation unloads; inspect it with ox.fs.read or ox.fs.grep. File pagination is a separate limit.`,
  ].join("\n\n");
}
