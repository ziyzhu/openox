import { homedir } from "node:os";
import { join } from "node:path";
import { parseArgs, type ParseArgsConfig } from "node:util";
import { AGENT_DEFAULT_PORT, type AgentDescription } from "@openox/protocol/agent";
import { AgentClient, agentEndpoint } from "./agent-client.ts";
import { keepAwake } from "./agent-awake.ts";
import { agentLog } from "./agent-log.ts";
import { piExecutable, type Approval } from "./agent-pi.ts";
import { AgentServer } from "./agent-serve.ts";
import { ensurePortFree, publish, tailnetIdentity, tailscaleBinary, type Tailnet } from "./agent-tailscale.ts";
import { fail, type SubCommand } from "./lib.ts";

const SERVE_USAGE = `Usage: ox agent serve [--port ${AGENT_DEFAULT_PORT}] [--local] [--allow-sleep] [--approve | --no-approve]

Publishes wss://<this machine>.ts.net:<port> through Tailscale Serve to this machine's owner by default.
Conversations start in your home folder unless a Host names another folder.
  --local               Loopback only at ws://127.0.0.1:<port>; do not publish through Tailscale
  --allow-sleep         Let macOS idle-sleep while serving`;
const DESCRIBE_USAGE = `Usage: ox agent describe [--endpoint ws://127.0.0.1:${AGENT_DEFAULT_PORT}] [--json]`;

export const AGENT_COMMANDS: Record<string, SubCommand> = {
  serve: { desc: "Serve pi on this machine to Ox over WebSocket JSON-RPC, published through Tailscale Serve", fn: serve },
  describe: { desc: "Show an agent endpoint's implementation, default folder and methods (--endpoint, --json)", fn: describe },
};

type Publication = { kind: "local" } | { kind: "tailscale"; binary: string; tailnet: Tailnet };

async function serve(args: string[]): Promise<void> {
  const { values } = parse(args, {
    port: { type: "string" },
    local: { type: "boolean" },
    "allow-sleep": { type: "boolean" },
    approve: { type: "boolean" },
    "no-approve": { type: "boolean" },
    help: { type: "boolean", short: "h" },
  }, SERVE_USAGE);
  if (values.help) {
    console.log(SERVE_USAGE);
    return;
  }
  if (values.approve && values["no-approve"]) fail("--approve and --no-approve cannot be combined");
  const port = Number(values.port ?? AGENT_DEFAULT_PORT);
  if (!Number.isInteger(port) || port < 0 || port > 65535) fail("--port must be an integer from 0 to 65535");
  if (port === 0 && !values.local) fail("--port 0 needs --local; Tailscale Serve publishes a fixed port");
  const approval: Approval = values.approve ? "approve" : values["no-approve"] ? "no-approve" : "default";
  const publication = await preparePublication(values.local === true, port);
  const awake = values["allow-sleep"] ? undefined : keepAwake();
  const server = await AgentServer.start({
    approval,
    executable: piExecutable(),
    stateDirectory: process.env.OX_AGENT_STATE_DIR ?? join(homedir(), ".ox", "agent-serve"),
    port,
    tailnet: publication.kind === "tailscale" ? publication.tailnet : undefined,
  }).catch(async (error: Error) => {
    await awake?.stop();
    return fail(error.message);
  });
  const published = publication.kind === "tailscale"
    ? await publish(publication.binary, publication.tailnet, port).catch(async (error: Error) => {
      await Promise.all([server.stop(), awake?.stop()]);
      return fail(error.message);
    })
    : undefined;
  const endpoint = published?.endpoint ?? server.url;
  agentLog("serve.published", { endpoint, publication: publication.kind, keepAwake: awake !== undefined });
  console.log(endpoint);
  let stopping = false;
  const shutdown = async (reason: string, code: number) => {
    if (stopping) return;
    stopping = true;
    agentLog("serve.shutdown", { reason });
    await published?.stop();
    await Promise.all([awake?.stop(), server.stop()]);
    process.exit(code);
  };
  process.once("SIGINT", () => void shutdown("SIGINT", 0));
  process.once("SIGTERM", () => void shutdown("SIGTERM", 0));
  void published?.exited.then(() => shutdown("tailscale_serve_exited", 1));
  void awake?.exited.then(() => shutdown("keep_awake_exited", 1));
}

async function preparePublication(local: boolean, port: number): Promise<Publication> {
  if (local) return { kind: "local" };
  const binary = tailscaleBinary();
  try {
    const tailnet = await tailnetIdentity(binary);
    await ensurePortFree(binary, tailnet, port);
    return { kind: "tailscale", binary, tailnet };
  } catch (error) {
    return fail((error as Error).message);
  }
}

async function describe(args: string[]): Promise<void> {
  const { values } = parse(args, {
    endpoint: { type: "string" },
    json: { type: "boolean" },
    help: { type: "boolean", short: "h" },
  }, DESCRIBE_USAGE);
  if (values.help) {
    console.log(DESCRIBE_USAGE);
    return;
  }
  const endpoint = agentEndpoint(values.endpoint ? String(values.endpoint) : undefined);
  const client = await AgentClient.connect(endpoint).catch((error: Error) => fail(error.message));
  try {
    const description = await client.request<AgentDescription>("agent.describe");
    if (values.json) console.log(JSON.stringify(description, null, 2));
    else {
      console.log(`${description.implementation.name} ${description.implementation.version} on ${description.machine}`);
      console.log(`cwd: ${description.cwd}`);
      for (const [name, versions] of Object.entries(description.protocols)) console.log(`${name}: ${versions.join(", ")}`);
      for (const method of description.methods) console.log(method);
    }
  } catch (error) {
    fail((error as Error).message);
  } finally {
    client.close();
  }
}

function parse<T extends NonNullable<ParseArgsConfig["options"]>>(args: string[], options: T, usage: string) {
  try {
    return parseArgs({ args, options, strict: true });
  } catch (error) {
    return fail(`${(error as Error).message}\n${usage}`);
  }
}
