import { realpath, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { parseArgs, type ParseArgsConfig } from "node:util";
import { AGENT_DEFAULT_PORT, type AgentDescription } from "@openox/protocol/agent";
import { AgentClient, agentEndpoint } from "./agent-client.ts";
import { keepAwake } from "./agent-awake.ts";
import { agentLog } from "./agent-log.ts";
import { piExecutable, type Approval } from "./agent-pi.ts";
import { AgentServer, PI_BUILTIN_TOOLS } from "./agent-serve.ts";
import { ensurePortFree, publish, tailnetIdentity, tailscaleBinary, type Tailnet } from "./agent-tailscale.ts";
import { fail, type SubCommand } from "./lib.ts";

const SERVE_USAGE = `Usage: ox agent serve [--port ${AGENT_DEFAULT_PORT}] [--directory <folder>]... [--tools <list>] [--local] [--allow-sleep] [--approve | --no-approve]

Publishes wss://<this machine>.ts.net:<port> through Tailscale Serve to this machine's owner by default.
  --directory <folder>  Authorize a folder for conversations (repeatable; --cwd is an alias); authorized folders persist
  Conversations started without a folder get their own working folder in the agent's state directory.
  --tools <list>        pi built-in tools Hosts may turn on, comma-separated (default: ${PI_BUILTIN_TOOLS.join(",")})
  --local               Loopback only at ws://127.0.0.1:<port>; do not publish through Tailscale
  --allow-sleep         Let macOS idle-sleep while serving`;
const DESCRIBE_USAGE = `Usage: ox agent describe [--endpoint ws://127.0.0.1:${AGENT_DEFAULT_PORT}] [--json]`;
const FOLDERS_USAGE = `Usage: ox agent folders [list | add <folder> | remove <folder>] [--endpoint ws://127.0.0.1:${AGENT_DEFAULT_PORT}]

Changes the folders a running ox agent serve authorizes; new and resumed pi processes use the updated list.`;

export const AGENT_COMMANDS: Record<string, SubCommand> = {
  serve: { desc: "Serve pi on this machine to Ox Hosts over WebSocket JSON-RPC, published through Tailscale Serve", fn: serve },
  describe: { desc: "Show an agent endpoint's implementation, folders and methods (--endpoint, --json)", fn: describe },
  folders: { desc: "List, add or remove the folders an agent endpoint authorizes (--endpoint)", fn: folders },
};

type Publication = { kind: "local" } | { kind: "tailscale"; binary: string; tailnet: Tailnet };

async function serve(args: string[]): Promise<void> {
  const { values } = parse(args, {
    port: { type: "string" },
    directory: { type: "string", multiple: true },
    cwd: { type: "string" },
    tools: { type: "string" },
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
  const requested = [...(values.directory ?? []), ...(values.cwd ? [values.cwd] : [])];
  const folders = [...new Set(await Promise.all(requested.map(workspaceRoot)))];
  const tools = values.tools === undefined ? undefined : toolLimit(values.tools);
  const approval: Approval = values.approve ? "approve" : values["no-approve"] ? "no-approve" : "default";
  const publication = await preparePublication(values.local === true, port);
  const awake = values["allow-sleep"] ? undefined : keepAwake();
  const server = await AgentServer.start({
    folders,
    tools,
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

function toolLimit(list: string): string[] {
  const tools = [...new Set(list.split(",").map((tool) => tool.trim()).filter(Boolean))];
  const unknown = tools.filter((tool) => !(PI_BUILTIN_TOOLS as readonly string[]).includes(tool));
  return unknown.length ? fail(`--tools: unknown ${unknown.join(", ")}; choose from ${PI_BUILTIN_TOOLS.join(",")}`) : tools;
}

async function workspaceRoot(path: string): Promise<string> {
  const resolved = await realpath(resolve(path)).catch(() => undefined);
  const directory = resolved && await stat(resolved).then((info) => info.isDirectory(), () => false);
  return resolved && directory ? resolved : fail(`--directory ${path} is not a folder`);
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
      for (const folder of description.folders ?? [description.folder]) console.log(`folder: ${folder}`);
      for (const [name, versions] of Object.entries(description.protocols)) console.log(`${name}: ${versions.join(", ")}`);
      for (const method of description.methods) console.log(method);
    }
  } catch (error) {
    fail((error as Error).message);
  } finally {
    client.close();
  }
}

async function folders(args: string[]): Promise<void> {
  const { values, positionals } = parse(args, {
    endpoint: { type: "string" },
    help: { type: "boolean", short: "h" },
  }, FOLDERS_USAGE, true);
  const [action = "list", path, ...extra] = positionals;
  if (values.help) {
    console.log(FOLDERS_USAGE);
    return;
  }
  const valid = action === "list" ? path === undefined : (action === "add" || action === "remove") && path !== undefined;
  if (!valid || extra.length) fail(FOLDERS_USAGE);
  const endpoint = agentEndpoint(values.endpoint ? String(values.endpoint) : undefined);
  const client = await AgentClient.connect(endpoint).catch((error: Error) => fail(error.message));
  try {
    const params = path === undefined ? {} : { path: resolve(path) };
    const result = await client.request<{ folders: string[] }>(`folders.${action}`, params);
    for (const folder of result.folders) console.log(folder);
  } catch (error) {
    fail((error as Error).message);
  } finally {
    client.close();
  }
}

function parse<T extends NonNullable<ParseArgsConfig["options"]>>(args: string[], options: T, usage: string, allowPositionals = false) {
  try {
    return parseArgs({ args, options, strict: true, allowPositionals });
  } catch (error) {
    return fail(`${(error as Error).message}\n${usage}`);
  }
}
