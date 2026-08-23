type CdpRequest = {
  id: number;
  method: string;
  params?: Record<string, unknown>;
  sessionId?: string;
};

type CdpResponse = {
  id?: number;
  result?: unknown;
  error?: { code?: number; message?: string; data?: string };
  method?: string;
  params?: unknown;
  sessionId?: string;
};

type PendingRequest = {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timeout: ReturnType<typeof setTimeout>;
};

export type CdpEventHandler = (params: unknown, sessionId: string | undefined) => void;

export class CdpError extends Error {
  constructor(
    message: string,
    readonly code?: number,
    readonly data?: string,
  ) {
    super(message);
    this.name = "CdpError";
  }
}

export class CdpConnection {
  private nextId = 1;
  private pending = new Map<number, PendingRequest>();
  private listeners = new Map<string, Set<CdpEventHandler>>();
  private closed = false;

  private constructor(private readonly socket: WebSocket) {
    socket.onmessage = (event) => this.receive(event.data);
    socket.onerror = () => this.finish(new Error("CDP WebSocket failed"));
    socket.onclose = () => this.finish(new Error("CDP WebSocket closed"));
  }

  static connect(url: string, timeoutMs = 5_000): Promise<CdpConnection> {
    return new Promise((resolve, reject) => {
      const socket = new WebSocket(url);
      let settled = false;
      const timeout = setTimeout(() => {
        if (settled) return;
        settled = true;
        socket.close();
        reject(new Error(`CDP connection timed out after ${timeoutMs}ms`));
      }, timeoutMs);
      socket.onopen = () => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        resolve(new CdpConnection(socket));
      };
      socket.onerror = () => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        reject(new Error("CDP connection failed"));
      };
    });
  }

  send<T = Record<string, unknown>>(
    method: string,
    params: Record<string, unknown> = {},
    sessionId?: string,
    timeoutMs = 30_000,
  ): Promise<T> {
    if (this.closed) return Promise.reject(new Error("CDP connection is closed"));
    const id = this.nextId++;
    const request: CdpRequest = { id, method };
    if (Object.keys(params).length > 0) request.params = params;
    if (sessionId) request.sessionId = sessionId;
    return new Promise<T>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP ${method} timed out after ${timeoutMs}ms`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (value) => resolve(value as T),
        reject,
        timeout,
      });
      try {
        this.socket.send(JSON.stringify(request));
      } catch (error) {
        clearTimeout(timeout);
        this.pending.delete(id);
        reject(error as Error);
      }
    });
  }

  on(method: string, handler: CdpEventHandler, sessionId?: string): () => void {
    const key = this.listenerKey(method, sessionId);
    const handlers = this.listeners.get(key) ?? new Set<CdpEventHandler>();
    handlers.add(handler);
    this.listeners.set(key, handlers);
    return () => {
      handlers.delete(handler);
      if (handlers.size === 0) this.listeners.delete(key);
    };
  }

  close(): void {
    if (this.closed) return;
    this.socket.close();
    this.finish(new Error("CDP connection closed"));
  }

  private receive(data: string | ArrayBuffer | Blob): void {
    const parse = async () => {
      const text = typeof data === "string"
        ? data
        : data instanceof ArrayBuffer
          ? new TextDecoder().decode(data)
          : await data.text();
      const message = JSON.parse(text) as CdpResponse;
      if (message.id !== undefined) {
        const pending = this.pending.get(message.id);
        if (!pending) return;
        this.pending.delete(message.id);
        clearTimeout(pending.timeout);
        if (message.error) {
          pending.reject(new CdpError(
            message.error.message ?? "CDP command failed",
            message.error.code,
            message.error.data,
          ));
        } else {
          pending.resolve(message.result ?? {});
        }
        return;
      }
      if (!message.method) return;
      const handlers = message.sessionId
        ? [
            this.listeners.get(this.listenerKey(message.method, message.sessionId)),
            this.listeners.get(this.listenerKey(message.method, undefined)),
          ]
        : [this.listeners.get(this.listenerKey(message.method, undefined))];
      for (const group of handlers) {
        for (const handler of group ?? []) handler(message.params ?? {}, message.sessionId);
      }
    };
    void parse().catch(() => {});
  }

  private listenerKey(method: string, sessionId: string | undefined): string {
    return `${sessionId ?? "*"}:${method}`;
  }

  private finish(error: Error): void {
    if (this.closed) return;
    this.closed = true;
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timeout);
      pending.reject(error);
    }
    this.pending.clear();
    this.listeners.clear();
  }
}
