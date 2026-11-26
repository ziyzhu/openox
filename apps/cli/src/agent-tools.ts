import { randomUUID } from "node:crypto";
import { Value } from "typebox/value";
import { AgentSchemas, type AgentContext, type AgentTool, type AgentToolCallResult } from "@openox/protocol/agent";
import { HOST_UNAVAILABLE } from "./agent-pi-extension.ts";
import { agentLog } from "./agent-log.ts";
import type { AgentSocket } from "./agent-serve.ts";

export type BridgeTarget = { id: string; context: AgentContext; tools: AgentTool[]; host: () => AgentSocket | undefined };
type Outcome = "ok" | "error" | "unavailable" | "cancelled";
type ToolCall = {
  socket: AgentSocket;
  conversationId: string;
  toolCallId: string;
  name: string;
  started: number;
  write: (record: Record<string, unknown>) => void;
  close: () => void;
};

const KEEPALIVE_MS = 15000;
const encoder = new TextEncoder();
const unavailable: AgentToolCallResult = { content: [{ type: "text", text: HOST_UNAVAILABLE }], isError: true };

export class ToolBridge {
  private server?: ReturnType<typeof Bun.serve>;
  private readonly calls = new Map<string, ToolCall>();
  private readonly resolve: (token: string) => BridgeTarget | undefined;

  constructor(resolve: (token: string) => BridgeTarget | undefined) {
    this.resolve = resolve;
  }

  start(): string {
    this.server = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      idleTimeout: 0,
      fetch: (request, server) => this.handle(request, server.requestIP(request)?.address),
    });
    return `http://127.0.0.1:${this.server.port}`;
  }

  stop(): void {
    for (const id of [...this.calls.keys()]) this.finish(id, unavailable, "unavailable");
    void this.server?.stop(true);
  }

  receiveResponse(socket: AgentSocket, message: Record<string, unknown>): void {
    const id = String(message.id);
    const call = this.calls.get(id);
    if (!call || call.socket !== socket) {
      agentLog("tool.unmatched_response", { connection: socket.data.id });
      return;
    }
    const error = message.error as { message?: unknown } | undefined;
    if (error) this.finish(id, { content: [{ type: "text", text: String(error.message ?? "Tool call failed") }], isError: true }, "error");
    else if (!Value.Check(AgentSchemas, AgentSchemas.AgentToolCallResult, message.result)) {
      this.finish(id, { content: [{ type: "text", text: "Ox Host returned an invalid tool result" }], isError: true }, "error");
    } else {
      const result = message.result as AgentToolCallResult;
      this.finish(id, result, result.isError ? "error" : "ok");
    }
  }

  receiveProgress(socket: AgentSocket, params: { id: string; toolCallId: string; message: string }): void {
    for (const call of this.calls.values()) {
      if (call.socket === socket && call.conversationId === params.id && call.toolCallId === params.toolCallId) {
        call.write({ type: "progress", message: params.message });
      }
    }
  }

  socketClosed(socket: AgentSocket): void {
    for (const [id, call] of [...this.calls]) if (call.socket === socket) this.finish(id, unavailable, "unavailable");
  }

  private async handle(request: Request, address: string | undefined): Promise<Response> {
    if (!isLoopback(address)) return new Response("Forbidden", { status: 403 });
    const [, token = "", ...route] = new URL(request.url).pathname.split("/");
    const target = this.resolve(token);
    if (!target) return new Response("Forbidden", { status: 403 });
    const path = route.join("/");
    if (request.method === "GET" && path === "context") return Response.json({ ...target.context, tools: target.tools });
    if (request.method === "POST" && path === "tools/call") {
      const body = await request.json().catch(() => undefined) as { toolCallId?: unknown; name?: unknown; args?: unknown } | undefined;
      if (typeof body?.toolCallId !== "string" || typeof body.name !== "string") return new Response("Invalid tool call", { status: 400 });
      return this.call(target, body.toolCallId, body.name, body.args ?? {}, request.signal);
    }
    return new Response("Not found", { status: 404 });
  }

  private call(target: BridgeTarget, toolCallId: string, name: string, args: unknown, signal: AbortSignal): Response {
    const socket = target.host();
    if (!socket) {
      agentLog("tool.call", { conversation: target.id, name, durationMs: 0, outcome: "unavailable" });
      return new Response(`${JSON.stringify({ type: "result", ...unavailable })}\n`);
    }
    const id = `tool-${randomUUID()}`;
    const started = performance.now();
    let controller!: ReadableStreamDefaultController<Uint8Array>;
    const stream = new ReadableStream<Uint8Array>({
      start(value) {
        controller = value;
        value.enqueue(line({ type: "accepted" }));
      },
      cancel: () => this.finish(id, undefined, "cancelled"),
    });
    const write = (record: Record<string, unknown>) => {
      try { controller.enqueue(line(record)); } catch {}
    };
    const keepalive = setInterval(() => write({ type: "keepalive" }), KEEPALIVE_MS);
    const close = () => {
      clearInterval(keepalive);
      try { controller.close(); } catch {}
    };
    this.calls.set(id, { socket, conversationId: target.id, toolCallId, name, started, write, close });
    signal.addEventListener("abort", () => this.finish(id, undefined, "cancelled"), { once: true });
    socket.send(JSON.stringify({ jsonrpc: "2.0", id, method: "tools.call", params: { id: target.id, toolCallId, name, args } }));
    return new Response(stream, { headers: { "content-type": "application/x-ndjson" } });
  }

  private finish(id: string, result: AgentToolCallResult | undefined, outcome: Outcome): void {
    const call = this.calls.get(id);
    if (!call) return;
    this.calls.delete(id);
    if (result) call.write({ type: "result", ...result });
    call.close();
    agentLog("tool.call", {
      conversation: call.conversationId,
      name: call.name,
      durationMs: Math.round(performance.now() - call.started),
      outcome,
    });
  }
}

function line(record: Record<string, unknown>): Uint8Array {
  return encoder.encode(`${JSON.stringify(record)}\n`);
}

function isLoopback(address: string | undefined): boolean {
  return address === "127.0.0.1" || address === "::1" || address === "::ffff:127.0.0.1";
}
