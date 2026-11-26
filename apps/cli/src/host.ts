import { HostRPCClient } from "./host-rpc.ts";
import { fail, type CliContext, type SubCommand } from "./lib.ts";
import { discover } from "./discover.ts";
import { logs } from "./logs.ts";
import { providers } from "./providers.ts";
import { agents } from "./host-agents.ts";

export const HOST_COMMANDS: Record<string, SubCommand> = {
  describe: { desc: "Show the Ox app's device, active Profile, protocol versions and methods (--json)", fn: describe },
  list: { desc: "List reachable devices running Ox (--all includes unavailable candidates)", fn: discover },
  discover: { desc: "Alias for host list", fn: discover },
  logs: { desc: "Read or follow the active Profile's structured logs", fn: logs },
  providers: { desc: "List the active Profile's model providers and their models", fn: providers },
  agents: { desc: "List, add or remove the active Profile's remote agents (ox agent serve endpoints)", fn: agents },
};

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
      if (description.device) console.log(`device: ${description.device.name}`);
      if (description.profile) console.log(`profile: ${description.profile.name} (${description.profile.id})`);
      for (const [name, versions] of Object.entries(description.protocols).sort(([a], [b]) => a.localeCompare(b))) console.log(`${name}: ${versions.join(", ")}`);
      for (const method of description.methods) console.log(method);
    }
  } catch (error) {
    fail((error as Error).message);
  } finally {
    client.close();
  }
}
