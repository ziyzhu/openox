import { validateResponse } from "@openox/protocol";

const DEFAULT_ENDPOINT = "ws://127.0.0.1:9876";

export function hostEndpoint(): string {
  const value = process.env.OX_HOST_ENDPOINT ?? process.env.OX_DEBUG_ENDPOINT ?? DEFAULT_ENDPOINT;
  const url = new URL(value);
  if (!["ws:", "wss:"].includes(url.protocol) || !url.port) throw new Error("Ox Host endpoint must be a ws:// or wss:// URL with a port");
  return url.toString();
}

export class HostRPCError extends Error {
  readonly code?: number;
  readonly data?: unknown;

  constructor(message: string, code?: number, data?: unknown) {
    super(message);
    this.code = code;
    this.data = data;
    this.name = "HostRPCError";
  }
}

export class HostConnection {
  private socket?: WebSocket;
  private disposed = false;
  private connectionGeneration = 0;

  get generation(): number { return this.connectionGeneration; }
  private readonly pending = new Map<string, {
    request: { jsonrpc: "2.0"; id: string; method: string; params: Record<string, unknown> };
    sent: boolean;
    resolve: (value: unknown) => void;
    reject: (error: Error) => void;
    timer: ReturnType<typeof setTimeout>;
  }>();

  private readonly endpoint: string;

  constructor(endpoint = hostEndpoint()) {
    this.endpoint = endpoint;
  }

  request(method: string, params: Record<string, unknown>, timeoutMs: number): Promise<unknown> {
    if (this.disposed) return Promise.reject(new Error("connection is closed"));
    const request = { jsonrpc: "2.0" as const, id: crypto.randomUUID(), method, params };
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.finish(request.id, pending => pending.reject(requestFailure(`timeout after ${timeoutMs}ms`, pending.sent)));
        if (!this.pending.size) this.disconnect("connection timed out");
      }, timeoutMs);
      this.pending.set(request.id, { request, sent: false, resolve, reject, timer });
      try {
        const socket = this.connect();
        if (socket.readyState === WebSocket.OPEN) {
          socket.send(JSON.stringify(request));
          this.pending.get(request.id)!.sent = true;
        }
      } catch (error) {
        this.disconnect(`Host connection failed: ${(error as Error).message}`);
      }
    });
  }

  close(): void {
    this.disposed = true;
    this.disconnect("connection closed");
  }

  private connect(): WebSocket {
    if (this.socket) return this.socket;
    const socket = new WebSocket(this.endpoint);
    this.socket = socket;
    socket.onopen = () => {
      if (this.socket !== socket) return;
      try {
        for (const pending of this.pending.values()) {
          socket.send(JSON.stringify(pending.request));
          pending.sent = true;
        }
      }
      catch { this.disconnect("Host request could not be sent"); }
    };
    socket.onerror = () => {
      if (this.socket === socket) this.disconnect("Host connection failed");
    };
    socket.onclose = () => {
      if (this.socket === socket) this.disconnect("Host connection closed before response");
    };
    socket.onmessage = event => {
      if (this.socket === socket) this.receive(event);
    };
    return socket;
  }

  private receive(event: MessageEvent): void {
    let message: unknown;
    try {
      message = JSON.parse(typeof event.data === "string" ? event.data : new TextDecoder().decode(event.data as ArrayBuffer));
    } catch {
      this.disconnect("Host returned malformed JSON");
      return;
    }
    if (!isObject(message) || message.jsonrpc !== "2.0") {
      this.disconnect("Host returned an invalid JSON-RPC response; update the Host and CLI together");
      return;
    }
    if (!("id" in message) && typeof message.method === "string") return;
    if (typeof message.id !== "string") {
      this.disconnect("Host returned a response without a matching request ID");
      return;
    }
    this.finish(message.id, pending => {
      if (!validateResponse(message)) pending.reject(requestFailure("Host returned an invalid JSON-RPC response", pending.sent));
      else if (Object.hasOwn(message, "result")) pending.resolve(message.result);
      else {
        const error = message.error as { code: number; message: string; data?: unknown };
        pending.reject(new HostRPCError(error.message, error.code, error.data));
      }
    });
  }

  private finish(id: string, complete: (pending: NonNullable<ReturnType<typeof this.pending.get>>) => void): void {
    const pending = this.pending.get(id);
    if (!pending) return;
    clearTimeout(pending.timer);
    this.pending.delete(id);
    complete(pending);
  }

  private disconnect(message: string): void {
    const socket = this.socket;
    this.socket = undefined;
    if (socket) this.connectionGeneration++;
    for (const id of this.pending.keys()) this.finish(id, pending => pending.reject(requestFailure(message, pending.sent)));
    socket?.close();
  }
}

function requestFailure(message: string, sent: boolean): Error {
  return new Error(`${message}. ${sent
    ? "Request outcome unknown; reconnect and inspect state before retrying. This request was not automatically resent."
    : "Host unavailable; open Ox, enable Host connections, and check the endpoint and access configuration (Tailscale or opt-in Debug Simulator loopback)."}`);
}

export function isObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
