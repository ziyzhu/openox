import { fail, failResult, type CliContext } from "./lib.ts";
import { createServiceRuntime, type RuntimeSession } from "./service-runtime.ts";

export async function sessions(args: string[], context: CliContext): Promise<void> {
  let timeoutMs = 30_000;
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    if (argument === "--timeout") timeoutMs = Number(args[++index]) || 30_000;
    else if (argument === "-h" || argument === "--help") {
      console.log("Usage: ox [--runtime <ios|chrome>] sessions [--timeout 30000]");
      return;
    } else fail(`unknown sessions option: ${argument}`);
  }
  const result = await createServiceRuntime(context.runtime, context.repository).sessions(timeoutMs);
  if (!result.ok) failResult("sessions", result.error);
  const rows = (result.sessions as RuntimeSession[] | undefined) ?? [];
  process.stdout.write(`${JSON.stringify(rows, null, 2)}\n`);
}
