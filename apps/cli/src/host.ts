import { HostRPCClient } from "./host-rpc.ts";
import { dispatch, fail, type CliContext, type SubCommand } from "./lib.ts";

export const SUBS: Record<string, SubCommand> = {
  describe: { desc: "Show Host identity, supported protocol versions and methods (--json)", fn: describe },
};

export async function host(args: string[], context: CliContext): Promise<void> {
  return dispatch("host", "Inspect Host compatibility.", SUBS, args, context);
}

async function describe(args: string[], context: CliContext): Promise<void> {
  let json = false;
  let timeoutMs = 30000;
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    if (argument === "--json") json = true;
    else if (argument === "--timeout" || argument.startsWith("--timeout=")) {
      timeoutMs = Number(argument === "--timeout" ? args[++index] : argument.slice(10));
      if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) fail("--timeout must be a positive number");
    } else if (argument === "--help" || argument === "-h") {
      console.log("Usage: ox [--host <ws-url>] host describe [--json] [--timeout 30000]");
      return;
    } else fail(`unknown option: ${argument}`);
  }
  const client = new HostRPCClient(context.host);
  try {
    const description = await client.describe(timeoutMs);
    if (json) console.log(JSON.stringify(description, null, 2));
    else {
      const { name, version, build } = description.implementation;
      console.log(`${name} ${version} (${build})`);
      for (const [name, versions] of Object.entries(description.protocols).sort(([a], [b]) => a.localeCompare(b))) console.log(`${name}: ${versions.join(", ")}`);
      for (const method of description.methods) console.log(method);
    }
  } catch (error) {
    fail((error as Error).message);
  } finally {
    client.close();
  }
}
