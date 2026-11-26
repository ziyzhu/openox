import { AGENT_DEFAULT_PORT } from "@openox/protocol/agent";

export type AgentNotificationHandler = (method: string, params: Record<string, unknown>) => void;
export type AgentRequestHandler = (method: string, params: Record<string, unknown>) => Promise<unknown>;

export function agentEndpoint(value = process.env.OX_AGENT_ENDPOINT ?? `ws://127.0.0.1:${AGENT_DEFAULT_PORT}`): string {
  const url = new URL(value);
  if (!["ws:", "wss:"].includes(url.protocol)) throw new Error("Agent endpoint must be a ws:// or wss:// URL");
  if (url.protocol === "ws:" && !url.port) url.port = String(AGENT_DEFAULT_PORT);
  return url.toString();
}

export class AgentRPCError extends Error {
  readonly code: number;

  constructor(code: number, message: string) {
    super(message);
    this.code = code;
  }
}

export class AgentClient {
  private readonly pending = new Map<string, { resolve: (value: unknown) => void; reject: (error: Error) => void }>();
  private sequence = 0;
  onNotification: AgentNotificationHandler = () => {};
  onRequest: AgentRequestHandler = async (method) => { throw new AgentRPCError(-32601, `Method not found: ${method}`); };

  private readonly socket: WebSocket;

  private constructor(socket: WebSocket) {
    this.socket = socket;
    socket.onmessage = (event) => this.receive(String(event.data));
    socket.onclose = () => {
      for (const pending of this.pending.values()) pending.reject(new Error("Agent connection closed before response"));
      this.pending.clear();
    };
  }

  static connect(endpoint: string): Promise<AgentClient> {
    return new Promise((resolve, reject) => {
      const socket = new WebSocket(agentEndpoint(endpoint));
      socket.onopen = () => resolve(new AgentClient(socket));
      socket.onerror = () => reject(new Error(`Could not connect to ${endpoint}; start ox agent serve and check the endpoint`));
    });
  }

  request<T = Record<string, unknown>>(method: string, params: Record<string, unknown> = {}, timeoutMs = 30000): Promise<T> {
    const id = `client-${++this.sequence}`;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} timed out after ${timeoutMs}ms`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (value) => { clearTimeout(timer); resolve(value as T); },
        reject: (error) => { clearTimeout(timer); reject(error); },
      });
      this.socket.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    });
  }

  notify(method: string, params: Record<string, unknown>): void {
    this.socket.send(JSON.stringify({ jsonrpc: "2.0", method, params }));
  }

  close(): void { this.socket.close(); }

  private receive(raw: string): void {
    const message = JSON.parse(raw) as Record<string, unknown>;
    if (typeof message.method === "string" && message.id !== undefined) void this.answer(message.id, message.method, message.params as Record<string, unknown>);
    else if (typeof message.method === "string") this.onNotification(message.method, message.params as Record<string, unknown>);
    else {
      const pending = this.pending.get(String(message.id));
      if (!pending) return;
      this.pending.delete(String(message.id));
      const error = message.error as { code: number; message: string } | undefined;
      if (error) pending.reject(new AgentRPCError(error.code, error.message));
      else pending.resolve(message.result);
    }
  }

  private async answer(id: unknown, method: string, params: Record<string, unknown>): Promise<void> {
    try {
      const result = await this.onRequest(method, params);
      this.socket.send(JSON.stringify({ jsonrpc: "2.0", id, result }));
    } catch (error) {
      const code = error instanceof AgentRPCError ? error.code : -32000;
      this.socket.send(JSON.stringify({ jsonrpc: "2.0", id, error: { code, message: (error as Error).message } }));
    }
  }
}
