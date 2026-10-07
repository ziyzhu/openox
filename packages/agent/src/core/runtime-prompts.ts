export type RuntimeEvent =
  | { type: "serviceSignIn"; domain: string; authorized: boolean }
  | { type: "botControl"; domain: string; argsJSON: string };
export interface ReceiptInvocation { id: string; name: string; state: "succeeded" | "failed" | "running" }
export interface OutputTruncation { id: string; maxLines: number; maxBytes: number }

export function runtimeEvent(event: RuntimeEvent) {
  if (typeof event?.domain !== "string") throw new Error("Runtime event requires a service domain");
  switch (event.type) {
    case "serviceSignIn":
      if (typeof event.authorized !== "boolean") throw new Error("Sign-in event requires authorization state");
      return `[system] The user just ${event.authorized ? "authorized" : "signed in to"} ${event.domain}. Continue the task that needed it.`;
    case "botControl":
      if (typeof event.argsJSON !== "string") throw new Error("Verification event requires serialized arguments");
      return `[system] The user just completed bot control for ${event.domain} with args ${event.argsJSON}. Continue the task. The verification page may already have completed the operation, so inspect its resulting state before retrying a write.`;
    default: throw new Error("Unknown runtime event");
  }
}

export function failureReceipt(input: { invocations: ReceiptInvocation[]; omittedCalls?: number }) {
  if (!Array.isArray(input?.invocations)) throw new Error("Failure receipt requires invocations");
  const omittedCalls = input.omittedCalls ?? 0;
  if (!Number.isSafeInteger(omittedCalls) || omittedCalls < 0) throw new Error("Invalid omitted invocation count");
  const statuses = { succeeded: "succeeded", failed: "failed", running: "incomplete/unknown outcome" };
  const counts = new Map<string, number>();
  for (const invocation of input.invocations) {
    if (typeof invocation?.id !== "string" || typeof invocation?.name !== "string" || !Object.hasOwn(statuses, invocation.state)) throw new Error("Invalid receipt invocation");
    const status = statuses[invocation.state];
    counts.set(status, (counts.get(status) ?? 0) + 1);
  }
  const summary = [...counts].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0).map(([status, count]) => `${status}: ${count}`).join(", ");
  const rows = input.invocations.length <= 20 ? input.invocations : [...input.invocations.slice(0, 10), ...input.invocations.slice(-10)];
  const segmenter = new Intl.Segmenter("en", { granularity: "grapheme" });
  const lines = [`Execution receipt (${input.invocations.length} calls; ${summary}):`, ...rows.map(invocation => {
    const name = [...segmenter.segment(invocation.name.split(/\s+/u).filter(Boolean).join(" "))].slice(0, 160).map(part => part.segment).join("");
    return `- ${name} [${invocation.id}]: ${statuses[invocation.state]}`;
  })];
  if (input.invocations.length > rows.length) lines.push(`${input.invocations.length - rows.length} middle calls omitted from this receipt.`);
  if (omittedCalls) lines.push(`${omittedCalls} additional calls were not retained; their outcomes are unknown in this receipt.`);
  lines.push("Calls are not rolled back. Verify external state before retrying writes, including failed or incomplete calls.");
  return lines.join("\n");
}

export function outputTruncation(input: OutputTruncation) {
  if (typeof input?.id !== "string" || !Number.isSafeInteger(input.maxLines) || input.maxLines < 1 || !Number.isSafeInteger(input.maxBytes) || input.maxBytes < 1) throw new Error("Invalid output truncation state");
  return `\n[Tool output truncated: showing the tail (${input.maxLines} lines or ${Math.floor(input.maxBytes / 1024)} KiB limit). Full output id: ${input.id}. Read with ox.output.read({ purpose: 'Read remaining output', id: '${input.id}' }), then filter or slice before printing. Reference expires when this conversation is unloaded.]`;
}

export function imageReadGuidance(input: { path: string }) {
  if (typeof input?.path !== "string") throw new Error("Image guidance requires a virtual path");
  return `Use ox.vision.analyze({ purpose, source: "${input.path}" }) for local OCR, or ox.fs.attach({ purpose, path: "${input.path}" }) when original pixels are needed.`;
}
