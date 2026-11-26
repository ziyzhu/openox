import { requireEndpoint } from "./profile-request.ts";
import { fail, type CliContext } from "./lib.ts";

const usage = `Usage: ox [--profile <ws-url>] profile agents [list|add <name> <ws-url>|remove <ws-url>|conversations <ws-url>] [--json] [--timeout 30000]
       Manage the remote agents (ox agent serve endpoints) the Profile can run conversations on.`;

type AgentRow = { name: string; endpoint: string; status: string; implementation?: string; version?: string; machine?: string; folder?: string; error?: string; models: unknown[] };
type AgentConversationRow = { id: string; title: string; state: string; origin: string; updatedAt: string; profileConversationId?: string };

export async function agents(args: string[], context: CliContext): Promise<void> {
  let json = false;
  let timeoutMs = 30000;
  const words: string[] = [];
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    if (argument === "--json") json = true;
    else if (argument === "--timeout" || argument.startsWith("--timeout=")) {
      timeoutMs = Number(argument === "--timeout" ? args[++index] : argument.slice(10));
      if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) fail("--timeout must be a positive number");
    } else if (argument === "--help" || argument === "-h") {
      console.log(usage);
      return;
    } else if (argument.startsWith("--")) fail(`unknown option: ${argument}`);
    else words.push(argument);
  }
  const [action = "list", ...rest] = words;
  const print = (value: unknown, text: () => string) => console.log(json ? JSON.stringify(value, null, 2) : text());
  const row = (agent: AgentRow) => `${agent.name}\t${agent.status}\t${agent.endpoint}\t${[agent.implementation, agent.version, agent.machine, agent.folder].filter(Boolean).join(" ")}${agent.error ? `\t${agent.error}` : ""}`;
  switch (action) {
    case "list": {
      const result = await requireEndpoint("agents.list", context, timeoutMs) as { agents: AgentRow[] };
      print(result, () => result.agents.length ? result.agents.map(row).join("\n") : "no remote agents");
      return;
    }
    case "add": {
      const [name, endpoint] = rest;
      if (!name || !endpoint) fail("profile agents add requires <name> <ws-url>");
      const result = await requireEndpoint("agents.add", context, timeoutMs, { name, endpoint }) as { agent: AgentRow };
      print(result, () => row(result.agent));
      return;
    }
    case "remove": {
      const [endpoint] = rest;
      if (!endpoint) fail("profile agents remove requires <ws-url>");
      const result = await requireEndpoint("agents.remove", context, timeoutMs, { endpoint });
      print(result, () => `removed ${endpoint}`);
      return;
    }
    case "conversations": {
      const [endpoint] = rest;
      if (!endpoint) fail("profile agents conversations requires <ws-url>");
      const result = await requireEndpoint("agents.conversations", context, timeoutMs, { endpoint }) as { conversations: AgentConversationRow[] };
      print(result, () => result.conversations.map(item =>
        `${item.id}\t${item.state}\t${item.origin}\t${item.updatedAt}\t${item.profileConversationId ?? "-"}\t${item.title}`).join("\n") || "no conversations");
      return;
    }
    default:
      fail(`unknown profile agents action: ${action}\n${usage}`);
  }
}
