const DEFAULT_ENDPOINT = "ws://127.0.0.1:9876";

export function hostEndpoint(): string {
  const value = process.env.OX_HOST_ENDPOINT ?? process.env.OX_DEBUG_ENDPOINT ?? DEFAULT_ENDPOINT;
  const url = new URL(value);
  if (!["ws:", "wss:"].includes(url.protocol) || !url.port) throw new Error("Ox Host endpoint must be a ws:// or wss:// URL with a port");
  return url.toString();
}

export class HostRPCError extends Error {
  constructor(message: string, readonly code?: number, readonly data?: unknown) {
    super(message);
    this.name = "HostRPCError";
  }
}

export class HostConnection {
  private socket?: WebSocket;
  private disposed = false;
  private readonly pending = new Map<string, {
    request: { jsonrpc: "2.0"; id: string; method: string; params: Record<string, unknown> };
    resolve: (value: unknown) => void;
    reject: (error: Error) => void;
    timer: ReturnType<typeof setTimeout>;
  }>();

  constructor(private readonly endpoint = hostEndpoint()) {}

  request(method: string, params: Record<string, unknown>, timeoutMs: number): Promise<unknown> {
    if (this.disposed) return Promise.reject(new Error("connection is closed"));
    const request = { jsonrpc: "2.0" as const, id: crypto.randomUUID(), method, params };
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.finish(request.id, pending => pending.reject(new Error(`timeout after ${timeoutMs}ms`)));
        if (!this.pending.size) this.disconnect("connection timed out");
      }, timeoutMs);
      this.pending.set(request.id, { request, resolve, reject, timer });
      try {
        const socket = this.connect();
        if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(request));
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
      try { for (const { request } of this.pending.values()) socket.send(JSON.stringify(request)); }
      catch { this.disconnect("Host request could not be sent"); }
    };
    socket.onerror = () => {
      if (this.socket === socket) this.disconnect("Host connection failed; is the Ox Host running?");
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
    const hasResult = Object.hasOwn(message, "result");
    const hasError = Object.hasOwn(message, "error");
    this.finish(message.id, pending => {
      if (hasResult === hasError) pending.reject(new Error("Host returned an invalid JSON-RPC response"));
      else if (hasResult) pending.resolve(message.result);
      else if (isObject(message.error) && Number.isInteger(message.error.code) && typeof message.error.message === "string") {
        pending.reject(new HostRPCError(message.error.message, message.error.code as number, message.error.data));
      } else pending.reject(new Error("Host returned an invalid JSON-RPC response"));
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
    for (const id of this.pending.keys()) this.finish(id, pending => pending.reject(new Error(message)));
    socket?.close();
  }
}

export function isObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
