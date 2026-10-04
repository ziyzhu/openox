import { McpServer, ResourceTemplate } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import { diagnostic, type Sessions } from "./sessions.ts";

const sessionId = z.uuid();
const target = { sessionId, runtimeId: z.uuid(), commandId: z.uuid() };
const result = (value: unknown) => ({ content: [{ type: "text" as const, text: JSON.stringify(value) }] });

export function createMcpServer(sessions: Sessions): McpServer {
  const server = new McpServer({ name: "ox", version: "0.1.0" }, {
    instructions: "Manage Pi coding sessions on this computer. Tool acceptance is not task completion. Poll read_session to observe work. Reuse commandId only for retries with identical inputs; deduplication lasts until ox serve restarts (maximum 10,000 mutations). Never blindly resend after an ambiguous delivery error. Session processes outlive client connections. These agents can execute commands and modify files with the server user's permissions. Working-directory roots limit initial cwd, not tool access or sandboxing.",
  });
  const readOnly = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false };
  const mutation = { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true };

  server.registerTool("list_sessions", { description: "List managed live and saved sessions. Saved sessions must be resumed before reading their conversation.", inputSchema: {}, annotations: readOnly }, async () => result({ contractVersion: 1, sessions: sessions.list() }));
  server.registerTool("create_session", {
    description: "Create a durable session and launch Pi in the allowed working directory. Does not submit a prompt. Do not automatically retry: this creates a new session.",
    inputSchema: { cwd: z.string().min(1), name: z.string().max(200).optional(), model: z.object({ provider: z.string().min(1), id: z.string().min(1) }).optional() }, annotations: mutation,
  }, async (input) => result(await sessions.create(input)));
  server.registerTool("resume_session", { description: "Start a saved session or reuse its running Pi process. Does not resume unfinished work automatically.", inputSchema: { sessionId }, annotations: { ...mutation, idempotentHint: true } }, async ({ sessionId }) => result(await sessions.resume(sessionId)));
  server.registerTool("read_session", {
    description: "Read active-branch messages, current Pi state, latest activity and pending interactions. Poll while working. before is a message-index cursor for older messages; messages may change after compaction.",
    inputSchema: { sessionId, before: z.number().int().nonnegative().optional(), limit: z.number().int().min(1).max(20).default(10) }, annotations: readOnly,
  }, async ({ sessionId, before, limit }) => result(await sessions.read(sessionId, before, limit)));
  server.registerTool("send_message", {
    description: "Submit a prompt (idle only), steer active work, or queue a follow-up. Returns acceptance, not completion. Use read_session to obtain runtimeId and observe progress.",
    inputSchema: { ...target, message: z.string().min(1).max(100_000), intent: z.enum(["prompt", "steer", "follow_up"]).default("prompt") }, annotations: mutation,
  }, async ({ sessionId, runtimeId, commandId, message, intent }) => result(await sessions.mutate(sessionId, runtimeId, commandId, "send", { message, intent }, async (runtime) => {
    return runtime.request(intent, { message });
  })));
  server.registerTool("stop_session", {
    description: "Clear pending input and abort active work. Keeps the process and saved conversation. Does not roll back file changes.", inputSchema: target, annotations: mutation,
  }, async ({ sessionId, runtimeId, commandId }) => result(await sessions.mutate(sessionId, runtimeId, commandId, "stop", {}, async (runtime) => {
    const cleared = await runtime.request("clear_queue");
    await runtime.request("abort");
    return { stopped: true, cleared, state: await runtime.request("get_state") };
  })));
  server.registerTool("respond_to_interaction", {
    description: "Respond to a pending Pi dialog from read_session. Only approve an operation when the user's authorization covers it. Custom terminal components are unavailable in RPC mode.",
    inputSchema: { ...target, interactionId: z.string().min(1), response: z.object({ confirmed: z.boolean().optional(), value: z.string().max(100_000).optional(), cancelled: z.boolean().optional() }) }, annotations: mutation,
  }, async ({ sessionId, runtimeId, commandId, interactionId, response }) => result(await sessions.mutate(sessionId, runtimeId, commandId, "interaction", { interactionId, response }, async (runtime) => {
    await runtime.respond(interactionId, response);
    return { delivered: true };
  })));

  server.registerResource("sessions", "ox://sessions", { mimeType: "application/json" }, async (uri) => ({ contents: [{ uri: uri.href, mimeType: "application/json", text: JSON.stringify({ contractVersion: 1, sessions: sessions.list() }) }] }));
  server.registerResource("session", new ResourceTemplate("ox://sessions/{sessionId}", { list: undefined }), { mimeType: "application/json" }, async (uri, variables) => ({ contents: [{ uri: uri.href, mimeType: "application/json", text: JSON.stringify(await sessions.read(String(variables.sessionId), undefined, 10)) }] }));
  return server;
}

export function createHttpHandler(sessions: Sessions, allowedHosts: Set<string>): (request: Request) => Promise<Response> {
  return async (request) => {
    const url = new URL(request.url);
    if (request.headers.has("origin")) return new Response("Browser origins are not allowed", { status: 403 });
    if (!allowedHosts.has(url.hostname)) return new Response("Invalid host", { status: 403 });
    if (url.pathname === "/health" && request.method === "GET") return Response.json({ name: "ox", contractVersion: 1 });
    if (url.pathname !== "/mcp") return new Response("Not found", { status: 404 });
    // Stateless MCP connections never own Pi process lifetime. Clients poll snapshots.
    const mcp = createMcpServer(sessions);
    const transport = new WebStandardStreamableHTTPServerTransport({ enableJsonResponse: true, maxRequestBodySize: 1024 * 1024 });
    try {
      await mcp.connect(transport);
      return await transport.handleRequest(request);
    } catch {
      diagnostic("request_failed");
      return new Response("MCP request failed", { status: 500 });
    } finally { await mcp.close(); }
  };
}
