import { createHash } from "node:crypto";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema, type Tool } from "@modelcontextprotocol/sdk/types.js";
import packageMetadata from "../package.json";
import { createHostServiceRuntime } from "./service-runtime.ts";

function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

type ServiceTool = { tool: Tool; domain: string; action: string };

export async function serveServiceMCP(endpoint: string | undefined, timeoutMs: number): Promise<void> {
  const runtime = createHostServiceRuntime(endpoint);
  const server = new Server({ name: "ox", version: packageMetadata.version }, {
    capabilities: { tools: { listChanged: true } },
    instructions: "Ox service actions run on the selected Host under its existing approval policies. Tool input is wrapped in input; session and pageUrl optionally route website actions. Approval-required actions are not automatically approved. Complete login and other human interactions in Ox. Failed or timed-out calls may have effects; inspect state before retrying writes. Remote MCP actions appear after the Host discovers them.",
  });
  let tools = new Map<string, ServiceTool>();
  let signature = "";
  let refreshing: Promise<void> | undefined;

  async function refresh(): Promise<void> {
    if (refreshing) return refreshing;
    refreshing = (async () => {
      const result = await runtime.status(timeoutMs);
      const next = new Map<string, ServiceTool>();
      for (const service of result.services as Record<string, unknown>[]) {
        if (!Array.isArray(service.actions)) throw new Error("Host does not expose service action metadata; update the Ox Host to use service MCP.");
        const domain = String(service.domain);
        const definitions = object(service.manifest) && object(service.manifest.$defs) ? service.manifest.$defs : {};
        for (const action of service.actions) {
          if (!object(action) || typeof action.id !== "string" || !object(action.inputSchema)
            || (action.outputSchema !== null && !object(action.outputSchema))) {
            throw new Error(`Host returned an invalid action contract for ${domain}`);
          }
          const outputSchema = action.outputSchema === null ? { type: "null" } : action.outputSchema;
          const target = `${domain}:${action.id}`;
          const suffix = createHash("sha256").update(target).digest("hex").slice(0, 16);
          const name = `${target.replace(/[^a-zA-Z0-9_.-]/g, "_").slice(0, 110)}_${suffix}`;
          const tool: Tool = {
            name,
            title: `${String(service.title)}: ${String(action.label ?? action.id)}`,
            description: `${target}${typeof action.description === "string" ? ` — ${action.description}` : ""}. Host approval policies apply.`,
            inputSchema: {
              type: "object",
              properties: {
                input: action.inputSchema,
                session: {
                  type: "object",
                  description: "Exact descriptor returned by listSessions; never fabricate a session.",
                  properties: { id: { type: "string", minLength: 1 }, label: { type: "string", minLength: 1 }, url: { type: "string", minLength: 1 } },
                  required: ["id", "label", "url"],
                  additionalProperties: false,
                },
                pageUrl: { type: "string", description: "Initial public HTTPS target within the website service domain." },
              },
              required: ["input"],
              additionalProperties: false,
              $defs: { ...definitions, ...(object(action.inputSchema.$defs) ? action.inputSchema.$defs : {}) },
            },
            outputSchema: {
              type: "object",
              properties: { value: outputSchema },
              required: ["value"],
              additionalProperties: false,
              $defs: { ...definitions, ...(object(outputSchema.$defs) ? outputSchema.$defs : {}) },
            },
          };
          if (next.has(name)) throw new Error(`Duplicate MCP tool name for ${target}`);
          next.set(name, { tool, domain, action: action.id });
        }
      }
      const sorted = new Map([...next].sort(([a], [b]) => a.localeCompare(b)));
      const nextSignature = JSON.stringify([...sorted.values()].map(entry => entry.tool));
      const changed = signature !== "" && signature !== nextSignature;
      tools = sorted;
      signature = nextSignature;
      if (changed) await server.sendToolListChanged();
    })();
    try { await refreshing; }
    finally { refreshing = undefined; }
  }

  server.setRequestHandler(ListToolsRequestSchema, async () => {
    await refresh();
    return { tools: [...tools.values()].map(entry => entry.tool) };
  });
  server.setRequestHandler(CallToolRequestSchema, async request => {
    try {
      if (!signature) await refresh();
      const entry = tools.get(request.params.name);
      if (!entry) throw new Error(`Unknown or unavailable service tool: ${request.params.name}`);
      const args = request.params.arguments ?? {};
      if (!Object.hasOwn(args, "input") || Object.keys(args).some(key => !["input", "session", "pageUrl"].includes(key))) {
        throw new Error("Provide input matching the action schema, with optional session and pageUrl only");
      }
      let session: { id: string; label: string; url: string } | undefined;
      if (args.session !== undefined) {
        if (!object(args.session) || Object.keys(args.session).sort().join(",") !== "id,label,url"
          || !Object.values(args.session).every(value => typeof value === "string" && value.trim())) {
          throw new Error("session must be an exact listSessions descriptor with nonempty id, label, and url strings");
        }
        session = args.session as typeof session;
      }
      if (args.pageUrl !== undefined) {
        if (typeof args.pageUrl !== "string") throw new Error("pageUrl must be a public HTTPS URL");
        const url = new URL(args.pageUrl);
        if (url.protocol !== "https:" || url.username || url.password) throw new Error("pageUrl must be a public HTTPS URL without credentials");
      }
      const result = await runtime.invoke({ domain: entry.domain, action: entry.action, args: args.input,
        session, pageUrl: args.pageUrl as string | undefined, timeoutMs });
      const structuredContent = { value: result.value ?? null };
      return { structuredContent, content: [{ type: "text", text: JSON.stringify(structuredContent) }] };
    } catch (error) {
      return { isError: true, content: [{ type: "text", text: (error as Error).message }] };
    }
  });
  server.onerror = error => console.error(`Ox MCP: ${error.message}`);
  await server.connect(new StdioServerTransport());
  const timer = setInterval(() => {
    void refresh().catch(error => console.error(`Ox MCP discovery: ${(error as Error).message}`));
  }, 10000);
  await new Promise<void>(resolve => {
    const close = () => { void server.close(); };
    process.once("SIGINT", close);
    process.once("SIGTERM", close);
    process.stdin.once("end", close);
    server.onclose = () => {
      clearInterval(timer);
      process.removeListener("SIGINT", close);
      process.removeListener("SIGTERM", close);
      process.stdin.removeListener("end", close);
      resolve();
    };
  });
}
