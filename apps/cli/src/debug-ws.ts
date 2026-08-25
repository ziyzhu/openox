const DEFAULT_ENDPOINT = "ws://127.0.0.1:9876";

export type DebugResult =
  | ({ ok: true } & Record<string, unknown>)
  | ({ ok: false; error: string } & Record<string, unknown>);

export function debugEndpoint(): string {
  const value = process.env.OX_HOST_ENDPOINT ?? process.env.OX_DEBUG_ENDPOINT ?? DEFAULT_ENDPOINT;
  try {
    const url = new URL(value);
    return (url.protocol === "ws:" || url.protocol === "wss:") && url.port ? url.toString() : DEFAULT_ENDPOINT;
  } catch {
    return DEFAULT_ENDPOINT;
  }
}

export function runOnce(
  envelope: Record<string, unknown> & { id: string },
  timeoutMs: number,
  endpoint = debugEndpoint(),
): Promise<DebugResult> {
  return new Promise((resolve) => {
    const ws = new WebSocket(endpoint);
    let done = false;
    let timer: ReturnType<typeof setTimeout>;
    const finish = (result: DebugResult) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try { ws.close(); } catch {}
      resolve(result);
    };
    timer = setTimeout(() => finish({ ok: false, error: `timeout after ${timeoutMs}ms` }), timeoutMs);
    ws.onopen = () => ws.send(JSON.stringify(envelope));
    ws.onerror = (event: Event) => {
      const message = String((event as ErrorEvent).message ?? event);
      finish({ ok: false, error: `ws error (is the Ox Host running?): ${message}` });
    };
    ws.onclose = () => finish({ ok: false, error: "ws closed before result" });
    ws.onmessage = (event: MessageEvent) => {
      let message: any;
      try {
        message = JSON.parse(typeof event.data === "string"
          ? event.data
          : new TextDecoder().decode(event.data as ArrayBuffer));
      } catch {
        return;
      }
      if (message?.id !== envelope.id) return;
      finish(message.ok ? message : { ...message, ok: false, error: String(message.error ?? "unknown") });
    };
  });
}

export class DebugConnection {
  private socket?: WebSocket;
  private opening?: Promise<WebSocket>;
  private disposed = false;
  private readonly pending = new Map<string, {
    resolve: (result: DebugResult) => void;
    timer: ReturnType<typeof setTimeout>;
  }>();

  constructor(private readonly endpoint = debugEndpoint()) {}

  async request(envelope: Record<string, unknown> & { id: string }, timeoutMs: number): Promise<DebugResult> {
    if (this.disposed) return { ok: false, error: "connection is closed" };
    let socket: WebSocket;
    try {
      socket = await this.connect(timeoutMs);
    } catch (error) {
      return { ok: false, error: `ws error (is the Ox Host running?): ${(error as Error).message}` };
    }
    return new Promise(resolve => {
      const timer = setTimeout(() => {
        this.pending.delete(envelope.id);
        resolve({ ok: false, error: `timeout after ${timeoutMs}ms` });
      }, timeoutMs);
      this.pending.set(envelope.id, { resolve, timer });
      try {
        socket.send(JSON.stringify(envelope));
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(envelope.id);
        resolve({ ok: false, error: `ws send failed: ${(error as Error).message}` });
      }
    });
  }

  close(): void {
    this.disposed = true;
    this.socket?.close(1000);
    this.socket = undefined;
    this.opening = undefined;
    this.failPending("connection closed");
  }

  private connect(timeoutMs: number): Promise<WebSocket> {
    if (this.socket?.readyState === WebSocket.OPEN) return Promise.resolve(this.socket);
    if (this.opening) return this.opening;
    this.opening = new Promise((resolve, reject) => {
      const socket = new WebSocket(this.endpoint);
      const timer = setTimeout(() => {
        socket.close();
        reject(new Error(`timeout after ${timeoutMs}ms`));
      }, timeoutMs);
      socket.onopen = () => {
        clearTimeout(timer);
        this.socket = socket;
        this.opening = undefined;
        resolve(socket);
      };
      socket.onerror = (event: Event) => {
        if (socket.readyState !== WebSocket.OPEN) {
          clearTimeout(timer);
          this.opening = undefined;
          reject(new Error(String((event as ErrorEvent).message ?? event)));
        }
      };
      socket.onclose = () => {
        clearTimeout(timer);
        if (this.socket === socket) this.socket = undefined;
        this.opening = undefined;
        this.failPending("ws closed before result");
      };
      socket.onmessage = event => this.receive(event);
    });
    return this.opening;
  }

  private receive(event: MessageEvent): void {
    let message: any;
    try {
      message = JSON.parse(typeof event.data === "string"
        ? event.data
        : new TextDecoder().decode(event.data as ArrayBuffer));
    } catch {
      return;
    }
    if (typeof message?.id !== "string") return;
    const pending = this.pending.get(message.id);
    if (!pending) return;
    clearTimeout(pending.timer);
    this.pending.delete(message.id);
    pending.resolve(message.ok ? message : { ...message, ok: false, error: String(message.error ?? "unknown") });
  }

  private failPending(error: string): void {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.resolve({ ok: false, error });
    }
    this.pending.clear();
  }
}
