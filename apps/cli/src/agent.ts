import { realpath } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { parseArgs, type ParseArgsConfig } from "node:util";
import { AGENT_DEFAULT_PORT, type AgentDescription } from "@openox/protocol/agent";
import { AgentClient, agentEndpoint } from "./agent-client.ts";
import { agentLog } from "./agent-log.ts";
import { piExecutable, type Approval } from "./agent-pi.ts";
import { AgentServer } from "./agent-serve.ts";
import { fail, type SubCommand } from "./lib.ts";

const SERVE_USAGE = "Usage: ox agent serve [--port 9877] [--listen 127.0.0.1] [--cwd <folder>] [--approve | --no-approve]";
const DESCRIBE_USAGE = "Usage: ox agent describe [--endpoint ws://127.0.0.1:9877] [--json]";

export const AGENT_COMMANDS: Record<string, SubCommand> = {
  serve: { desc: "Serve pi on this machine to Ox Hosts over WebSocket JSON-RPC", fn: serve },
  describe: { desc: "Show an agent endpoint's implementation, folder and methods (--endpoint, --json)", fn: describe },
};

async function serve(args: string[]): Promise<void> {
  const { values } = parse(args, {
    port: { type: "string" },
    listen: { type: "string" },
    cwd: { type: "string" },
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
  const cwd = await realpath(resolve(String(values.cwd ?? process.cwd()))).catch(() => fail(`--cwd ${values.cwd} is not a folder`));
  const approval: Approval = values.approve ? "approve" : values["no-approve"] ? "no-approve" : "default";
  const server = await AgentServer.start({
    cwd,
    approval,
    executable: piExecutable(),
    stateDirectory: process.env.OX_AGENT_STATE_DIR ?? join(homedir(), ".ox", "agent-serve"),
    hostname: String(values.listen ?? "127.0.0.1"),
    port,
  });
  console.log(server.url);
  const shutdown = async (signal: string) => {
    agentLog("serve.signal", { signal });
    await server.stop();
    process.exit(0);
  };
  process.once("SIGINT", () => void shutdown("SIGINT"));
  process.once("SIGTERM", () => void shutdown("SIGTERM"));
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
      console.log(`folder: ${description.folder}`);
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
    return parseArgs({ args, options, strict: true, allowPositionals: false });
  } catch (error) {
    return fail(`${(error as Error).message}\n${usage}`);
  }
}
