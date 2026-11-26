import { ProfileRPCClient } from "./profile-rpc.ts";
import { fail, type CliContext, type SubCommand } from "./lib.ts";
import { discover } from "./discover.ts";
import { logs } from "./logs.ts";
import { providers } from "./providers.ts";
import { agents } from "./profile-agents.ts";

export const LIVE_PROFILE_COMMANDS: Record<string, SubCommand> = {
  describe: { desc: "Show the open Profile, its device, protocol versions and methods (--json)", fn: describe },
  discover: { desc: "List reachable devices with a Profile open in Ox (--all includes unavailable candidates)", fn: discover },
  logs: { desc: "Read or follow the Profile's structured logs", fn: logs },
  providers: { desc: "List the Profile's model providers and their models", fn: providers },
  agents: { desc: "List, add or remove the Profile's remote agents (ox agent serve endpoints)", fn: agents },
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
      console.log("Usage: ox [--profile <ws-url>] profile describe [--json] [--timeout 30000]");
      return;
    } else fail(`unknown option: ${argument}`);
  }
  const client = new ProfileRPCClient(context.endpoint);
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
