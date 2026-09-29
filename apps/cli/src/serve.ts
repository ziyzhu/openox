import { Value } from "@sinclair/typebox/value";
import { Type, type TSchema } from "@sinclair/typebox";
import { fail, terminalText, C } from "./lib.ts";
import { startTailscaleServe, type ManagedTailscaleServe } from "./serve-tailscale.ts";

type Arguments = Record<string, unknown>;
type Action = {
  title: string;
  description: string;
  inputSchema: TSchema;
  run: (input: Arguments, runner: HerdrRunner) => Promise<unknown>;
};
type HerdrRunner = (args: string[], timeoutMs?: number) => Promise<unknown>;

const target = Type.String({ minLength: 1, maxLength: 500 });
const timeout = Type.Integer({ minimum: 1_000, maximum: 300_000 });
const states = Type.Union([
  Type.Literal("idle"), Type.Literal("working"), Type.Literal("blocked"),
  Type.Literal("done"), Type.Literal("unknown"),
]);
const sources = Type.Union([
  Type.Literal("visible"), Type.Literal("recent"),
  Type.Literal("recent-unwrapped"), Type.Literal("detection"),
]);
const empty = Type.Object({}, { additionalProperties: false });

export const HERDR_ACTIONS: Record<string, Action> = {
  status: {
    title: "Herdr status",
    description: "Inspect the installed Herdr client and selected session.",
    inputSchema: empty,
    run: async (_, runner) => runner(["status", "--json"]),
  },
  agent_list: {
    title: "List Herdr agents",
    description: "List agents and their current states.",
    inputSchema: empty,
    run: async (_, runner) => runner(["agent", "list"]),
  },
  agent_get: {
    title: "Inspect Herdr agent",
    description: "Get structured details for one agent.",
    inputSchema: Type.Object({ target }, { additionalProperties: false }),
    run: async (input, runner) => runner(["agent", "get", input.target as string]),
  },
  agent_read: {
    title: "Read Herdr agent",
    description: "Read bounded terminal output from one agent.",
    inputSchema: Type.Object({
      target,
      source: Type.Optional(sources),
      lines: Type.Optional(Type.Integer({ minimum: 1, maximum: 500 })),
    }, { additionalProperties: false }),
    run: async (input, runner) => runner([
      "agent", "read", input.target as string,
      "--source", (input.source as string | undefined) ?? "recent",
      "--lines", String(input.lines ?? 100), "--format", "text",
    ]),
  },
  agent_prompt: {
    title: "Prompt Herdr agent",
    description: "Send text to one agent, optionally waiting for a resulting state.",
    inputSchema: Type.Object({
      target,
      text: Type.String({ minLength: 1, maxLength: 100_000 }),
      wait: Type.Optional(Type.Boolean()),
      until: Type.Optional(Type.Array(states, { uniqueItems: true })),
      timeout_ms: Type.Optional(timeout),
    }, { additionalProperties: false }),
    run: async (input, runner) => {
      const wait = input.wait === true;
      if (!wait && (input.until !== undefined || input.timeout_ms !== undefined)) {
        throw new Error("until and timeout_ms require wait=true");
      }
      const args = ["agent", "prompt", input.target as string, input.text as string];
      if (wait) {
        args.push("--wait", "--timeout", String(input.timeout_ms ?? 30_000));
        for (const state of (input.until as string[] | undefined) ?? []) args.push("--until", state);
      }
      return runner(args, wait ? Number(input.timeout_ms ?? 30_000) + 5_000 : undefined);
    },
  },
  agent_wait: {
    title: "Wait for Herdr agent",
    description: "Wait for one agent to reach a settled or requested state.",
    inputSchema: Type.Object({
      target,
      until: Type.Optional(Type.Array(states, { uniqueItems: true })),
      timeout_ms: Type.Optional(timeout),
    }, { additionalProperties: false }),
    run: async (input, runner) => {
      const duration = Number(input.timeout_ms ?? 30_000);
      const args = ["agent", "wait", input.target as string, "--timeout", String(duration)];
      for (const state of (input.until as string[] | undefined) ?? []) args.push("--until", state);
      return runner(args, duration + 5_000);
    },
  },
  workspace_list: {
    title: "List Herdr workspaces",
    description: "List workspaces in the selected session.",
    inputSchema: empty,
    run: async (_, runner) => runner(["workspace", "list"]),
  },
  pane_list: {
    title: "List Herdr panes",
    description: "List panes, optionally within a workspace.",
    inputSchema: Type.Object({ workspace: Type.Optional(target) }, { additionalProperties: false }),
    run: async (input, runner) => runner(input.workspace
      ? ["pane", "list", "--workspace", input.workspace as string]
      : ["pane", "list"]),
  },
};

const DEFAULT_ACTIONS = ["agent_list", "agent_get", "agent_read", "agent_prompt", "agent_wait"];

function object(value: unknown): Arguments {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error("arguments must be an object");
  return value as Arguments;
}

function rpc(id: unknown, result: unknown): Response {
  return Response.json({ jsonrpc: "2.0", id, result }, { headers: { "Cache-Control": "no-store" } });
}

function rpcError(id: unknown, code: number, message: string): Response {
  return Response.json({ jsonrpc: "2.0", id: id ?? null, error: { code, message } }, { headers: { "Cache-Control": "no-store" } });
}

function toolError(error: unknown): Arguments {
  return { content: [{ type: "text", text: error instanceof Error ? error.message : String(error) }], isError: true };
}

export function createMCPHandler(actions: string[], runner: HerdrRunner): (request: Request) => Promise<Response> {
  const selected = actions.map((name) => [name, HERDR_ACTIONS[name]!] as const);
  return async (request) => {
    const url = new URL(request.url);
    if (url.pathname === "/health") return Response.json({ ok: true, service: "ox-serve" });
    if (url.pathname !== "/mcp") return new Response("not found", { status: 404 });
    if (request.method !== "POST") return new Response(null, { status: 405, headers: { Allow: "POST" } });
    const contentLength = Number(request.headers.get("content-length") ?? "0");
    if (contentLength > 1_048_576) return new Response("request body too large", { status: 413 });
    let message: Arguments;
    try {
      const body = await request.text();
      if (new TextEncoder().encode(body).byteLength > 1_048_576) return new Response("request body too large", { status: 413 });
      message = object(JSON.parse(body));
    } catch {
      return rpcError(null, -32700, "Parse error");
    }
    if (message.jsonrpc !== "2.0" || typeof message.method !== "string") return rpcError(message.id, -32600, "Invalid Request");
    if (message.method === "notifications/initialized") return new Response(null, { status: 202 });
    if (message.method === "initialize") return rpc(message.id, {
      protocolVersion: "2025-11-25",
      capabilities: { tools: { listChanged: false } },
      serverInfo: { name: "Ox Serve", version: "1" },
      instructions: "Use the exposed tools to inspect or prompt agents in the selected Herdr session.",
    });
    if (message.method === "tools/list") return rpc(message.id, {
      tools: selected.map(([name, action]) => ({
        name, title: action.title, description: action.description,
        inputSchema: action.inputSchema,
        outputSchema: Type.Object({ result: Type.Unknown() }),
      })),
    });
    if (message.method === "tools/call") {
      let params: Arguments;
      try { params = object(message.params); }
      catch (error) { return rpc(message.id, toolError(error)); }
      const action = selected.find(([name]) => name === params.name)?.[1];
      if (!action) return rpc(message.id, toolError(new Error(`unknown tool: ${String(params.name)}`)));
      try {
        const input = object(params.arguments ?? {});
        if (!Value.Check(action.inputSchema, input)) throw new Error("invalid tool arguments");
        const result = await action.run(input, runner);
        return rpc(message.id, {
          content: [{ type: "text", text: JSON.stringify(result) }],
          structuredContent: { result },
        });
      } catch (error) { return rpc(message.id, toolError(error)); }
    }
    return rpcError(message.id, -32601, "Method not found");
  };
}

function environment(session?: string): Record<string, string> {
  const values = Object.fromEntries(Object.entries(process.env).filter((entry): entry is [string, string] => entry[1] !== undefined));
  if (session) values.HERDR_SESSION = session;
  return values;
}

async function runHerdr(args: string[], session: string | undefined, timeoutMs: number): Promise<string> {
  const child = Bun.spawn({
    cmd: [process.env.OX_HERDR_BIN ?? "herdr", ...args],
    env: environment(session), stdin: "ignore", stdout: "pipe", stderr: "pipe",
  });
  const timer = setTimeout(() => child.kill(), timeoutMs);
  try {
    const [code, stdout, stderr] = await Promise.all([
      child.exited, new Response(child.stdout).text(), new Response(child.stderr).text(),
    ]);
    if (code !== 0) throw new Error(stderr.trim() || stdout.trim() || `herdr exited with status ${code}`);
    return stdout.trim();
  } finally { clearTimeout(timer); }
}

function createHerdrRunner(session?: string): HerdrRunner {
  return async (args, timeoutMs = 30_000) => {
    const output = await runHerdr(args, session, timeoutMs);
    let value: unknown;
    try { value = JSON.parse(output); }
    catch { value = output ? { text: output } : {}; }
    if (value && typeof value === "object" && "error" in value) {
      const error = (value as Arguments).error;
      if (error && typeof error === "object" && "message" in error) throw new Error(String(error.message));
    }
    return value;
  };
}

type Options = { port: number; localOnly: boolean; session?: string; actions: string[] };

function parseOptions(args: string[]): Options | undefined {
  let port = 8787;
  let localOnly = false;
  let session: string | undefined;
  const actions: string[] = [];
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    if (argument === "--port" || argument.startsWith("--port=")) {
      port = Number(argument === "--port" ? args[++index] : argument.slice(7));
    } else if (argument === "--herdr-session" || argument.startsWith("--herdr-session=")) {
      session = argument === "--herdr-session" ? args[++index] : argument.slice(16);
      if (!session || session.startsWith("-")) fail("--herdr-session requires a name");
    } else if (argument === "--action" || argument.startsWith("--action=")) {
      const name = argument === "--action" ? args[++index] : argument.slice(9);
      if (!name || !HERDR_ACTIONS[name]) fail(`unknown action: ${name ?? ""}; choose from ${Object.keys(HERDR_ACTIONS).join(", ")}`);
      if (!actions.includes(name)) actions.push(name);
    } else if (argument === "--local-only") localOnly = true;
    else if (argument === "--help" || argument === "-h") {
      console.log("Usage: ox serve [--action <name>]... [--port 8787] [--herdr-session <name>] [--local-only]");
      console.log("Expose selected local Herdr actions as MCP tools. --action replaces the default agent actions.");
      console.log(`Actions: ${Object.keys(HERDR_ACTIONS).join(", ")}`);
      return undefined;
    } else fail(`unknown serve option: ${argument}`);
  }
  if (!Number.isInteger(port) || port < 1 || port > 65_535) fail("--port must be an integer from 1 through 65535");
  return { port, localOnly, session, actions: actions.length ? actions : DEFAULT_ACTIONS };
}

async function waitForShutdown(server: ReturnType<typeof Bun.serve>, tailscale?: ManagedTailscaleServe): Promise<void> {
  let stopping = false;
  let resolveSignal: () => void = () => {};
  const signal = new Promise<void>((resolve) => { resolveSignal = resolve; });
  const stop = () => { stopping = true; resolveSignal(); };
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
  try {
    if (!tailscale) { await signal; return; }
    const outcome = await Promise.race([signal.then(() => undefined), tailscale.exited]);
    if (!stopping && outcome !== undefined) throw new Error(await tailscale.exitMessage() || `Tailscale Serve exited with status ${outcome}`);
  } finally {
    process.off("SIGINT", stop);
    process.off("SIGTERM", stop);
    await tailscale?.stop();
    server.stop(true);
  }
}

export async function serve(args: string[]): Promise<void> {
  const options = parseOptions(args);
  if (!options) return;
  const version = await runHerdr(["--version"], options.session, 5_000);
  const server = Bun.serve({
    hostname: "127.0.0.1", port: options.port,
    fetch: createMCPHandler(options.actions, createHerdrRunner(options.session)),
  });
  console.log(`${terminalText("Ox Serve", [C.bold, C.harvest])} · ${version}`);
  console.log(`Actions: ${options.actions.join(", ")}`);
  if (options.localOnly) {
    console.log(`MCP endpoint: ${terminalText(`http://127.0.0.1:${server.port}/mcp`, [C.sky])}`);
    await waitForShutdown(server);
    return;
  }
  const tailscale = await startTailscaleServe(options.port).catch((error) => {
    server.stop(true);
    return fail((error as Error).message);
  });
  console.log(`MCP endpoint: ${terminalText(tailscale.endpoint, [C.sky])}`);
  console.log("Press Ctrl+C to stop sharing.");
  await waitForShutdown(server, tailscale);
}
