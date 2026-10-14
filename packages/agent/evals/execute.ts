import { createInterface } from "node:readline";
import { Readable } from "node:stream";
import { catalog } from "./stubs";

export async function execute(source: string, call: (name: string, args: Record<string, unknown>) => Promise<unknown>, signal?: AbortSignal) {
  const child = Bun.spawn([process.execPath, "--no-env-file", new URL("./execute-worker.ts", import.meta.url).pathname], {
    stdin: "pipe", stdout: "pipe", stderr: "pipe", env: {},
  });
  const logs: string[] = [];
  let bytes = 0;
  let failure: unknown;
  const abort = () => child.kill("SIGKILL");
  const timer = setTimeout(abort, 10_000);
  signal?.addEventListener("abort", abort, { once: true });
  try {
    signal?.throwIfAborted();
    child.stdin.write(JSON.stringify({ source, catalog }) + "\n");
    const lines = createInterface({ input: Readable.fromWeb(child.stdout as never) });
    for await (const line of lines) {
      bytes += Buffer.byteLength(line);
      if (bytes > 262_144) throw new Error("Execution output exceeds 256 KiB");
      const message = JSON.parse(line);
      if (message.logs) logs.push(...message.logs);
      if (message.inspection) await call(message.inspection.name, message.inspection.args);
      if (message.call) {
        const { id, name, args } = message.call;
        let reply;
        try { reply = { id, value: await call(name, args) }; }
        catch (error) { const e = error as Error & { code?: string; recovery?: string }; reply = { id, error: { code: e.code ?? "operation_failed", message: e.message, recovery: e.recovery ?? "Inspect state before retrying." } }; }
        child.stdin.write(JSON.stringify(reply) + "\n");
      }
      if (message.done) { failure = message.error; if (message.value !== undefined) logs.push(JSON.stringify(message.value)); break; }
    }
    const code = await child.exited;
    if (failure || code !== 0 || signal?.aborted) throw new Error(JSON.stringify(failure ?? { code: "execution_timeout", message: "Execution cancelled or exceeded its limit" }));
    return logs.join("\n");
  } finally { clearTimeout(timer); signal?.removeEventListener("abort", abort); child.kill(); }
}
