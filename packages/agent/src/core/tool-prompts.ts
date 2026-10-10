export const countWords = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"];
const countWord = (value: number) => countWords[value] ?? String(value);
const oxErrorGuidance = "Built-in errors provide `code`, `message`, and `recovery`. Use the stable code and recovery guidance rather than parsing message wording. Print caught errors with `console.error(error)` or return `{ code: error.code, message: error.message, recovery: error.recovery }` so recovery information remains visible.";
export interface ExecuteGuidanceInput {
  catalog: string; variant?: "ox" | "portable"; timeoutSeconds: number; maxLines: number; maxBytes: number;
  maxFetches?: number; maxTransientAttachments?: number; canCancelLoops?: boolean;
}

export function executeGuidance(input: ExecuteGuidanceInput) {
  if (typeof input?.catalog !== "string" || ![input.timeoutSeconds, input.maxLines, input.maxBytes].every(value => Number.isSafeInteger(value) && value > 0)
    || ![input.maxFetches ?? 8, input.maxTransientAttachments ?? 4].every(value => Number.isSafeInteger(value) && value >= 0)) throw new Error("Invalid execution guidance facts");
  const variant = input.variant ?? "portable";
  if (!Object.hasOwn(templates, variant)) throw new Error(`Unknown execution guidance variant: ${variant}`);
  return templates[variant](input);
}

const templates: Record<NonNullable<ExecuteGuidanceInput["variant"]>, (input: ExecuteGuidanceInput) => string> = {
  ox: input => `Run JavaScript inside an async function. \`await\` works. Print model-visible results with \`console.log\` or a top-level \`return\`. Use \`ox.user\` and service handoff helpers when the snippet must wait for the user.

The \`ox\` namespace provides these built-in capabilities:

${input.catalog}

Built-in signatures printed in the tree are callable contracts. Every built-in function exposes a synchronous, non-enumerable \`.help()\` method that returns its complete description, input schema, and output schema as compact text. Call a built-in directly when the shown fields cover the task. For nested options or output details omitted from a compact signature, inspect that function first, for example \`ox.web.fetch.help()\`. Inspect several independent functions in one JavaScript object when useful. Never infer option names from another API.

Operational \`ox.*\` calls require a short \`purpose\` describing the visible step; \`.help()\` never requires it. Attached-service summaries intentionally omit actions. Use \`ox.service.list({ purpose, kind? })\` to list all available services, or \`ox.service.listAttached({ purpose, kind? })\` when current attachment state is needed; \`kind\` filters \`web\`, \`api\`, \`ios\`, or \`mcp\` services. Call \`ox.service.inspect({ purpose, domain })\` for a compact exposed-action index and any user-controlled payment contract, then request the full action contracts needed with \`ox.service.inspect({ purpose, domain, actions: ["<action-id>"] })\` before invoking them. Invoke only backend-qualified names returned by service inspection: \`web:<domain>:<action>\`, \`api:<service>:<action>\`, \`ios:<app>:<action>\`, or \`mcp:<server>:<action>\`. Use \`ox.service.solve\` only for a service-declared human-verification handoff, and \`ox.service.pay\` only after preparing and pricing the transaction through exposed actions. Copy returned identifiers and option shapes exactly. Never guess omitted fields or probe with intentionally invalid calls. If a built-in error includes \`Full help\`, correct the call directly from that schema.

The runtime waits for up to ${input.timeoutSeconds} seconds of active execution time; this does not forcibly stop an infinite JavaScript loop. Use bounded loops. Waiting for a service action, sign-in, verification, payment, or user choice does not consume that time. Each execution may call \`ox.web.fetch\` at most ${countWord(input.maxFetches ?? 8)} times and add at most ${countWord(input.maxTransientAttachments ?? 4)} transient attachments to model context; presented artifacts do not count toward that attachment limit. Every execution is self-contained: never store state on \`globalThis\`. Batch larger work across executions and print concise progress, cursors, or partial results so the next execution can continue, or persist continuation state through an authorized virtual file.

Combine dependent operations in one snippet when they fit these budgets. Parallelize independent reads with \`Promise.allSettled\` when partial success is useful; an uncaught \`Promise.all\` rejection ends the execution and cancels pending calls. Serialize writes and approval-dependent operations. Await every call whose outcome matters; pending unawaited calls are cancelled when the snippet ends. Keep intermediate results in JavaScript; filter, aggregate, project fields, and limit rows before printing or returning only what the next reasoning step needs. ${oxErrorGuidance} Calls are real and are not rolled back on script failure. Use the failure receipt and inspect external state before retrying a write; failed or incomplete calls may still have had an effect.

\`ox.fs\` is the only filesystem API. \`read({ purpose, path, offset?, limit? })\` returns at most 2,000 lines or 50 KiB; use its nextOffset and diagnostics to continue. File-read pagination and execution-output clipping are separate limits. Combined console and return output is limited to the last ${input.maxLines} lines or ${Math.floor(input.maxBytes / 1024)} KiB, whichever is reached first, independent of the model. Oversized output includes a reference for \`ox.output.read\`; retrieve the complete string, then print the relevant slice or filtered result. Do not treat a truncated preview as the complete record. Output references are chat-local and expire when the chat is unloaded.`,
  portable: input => `Run JavaScript inside an async function. \`await\` works. Print model-visible results with \`console.log\` or a top-level \`return\`.

The execution exposes these capabilities:

${input.catalog}

Use only these exposed contracts. Inspect unfamiliar input and output schemas through available help. Never infer option names from another API or substitute another host or Profile.

The runtime waits for up to ${input.timeoutSeconds} seconds of active execution time. ${input.canCancelLoops ? "The runtime supports interrupting JavaScript loops." : "Cancellation does not forcibly stop an infinite JavaScript loop."} Use bounded loops. Every execution is self-contained: never store continuation state on \`globalThis\`. Use only exposed handoff and persistence contracts.

Combine dependent operations when they fit the budgets. Use \`Promise.allSettled\` for independent reads when partial success is useful; serialize writes and approval-dependent operations. Await every call whose outcome matters. Keep intermediate results in JavaScript and print or return only what the next reasoning step needs. Calls are real and are not rolled back on failure; verify outcomes and external state before retrying writes.

Combined console and return output is limited to the last ${input.maxLines} lines or ${Math.floor(input.maxBytes / 1024)} KiB, whichever is reached first. Do not treat a truncated preview as the complete record. Use only output-recovery contracts actually exposed by the owning host and Profile.`,
};
