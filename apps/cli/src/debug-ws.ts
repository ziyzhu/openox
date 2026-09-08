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

export async function runOnce(
  envelope: Record<string, unknown> & { id: string },
  timeoutMs: number,
  endpoint = debugEndpoint(),
): Promise<DebugResult> {
  const connection = new DebugConnection(endpoint);
  try {
    return await connection.request(envelope, timeoutMs);
  } finally {
    connection.close();
  }
}

export class DebugConnection {
  private socket?: WebSocket;
  private disposed = false;
  private readonly pending = new Map<string, {
    envelope: Record<string, unknown> & { id: string };
    resolve: (result: DebugResult) => void;
    timer: ReturnType<typeof setTimeout>;
  }>();

  constructor(private readonly endpoint = debugEndpoint()) {}

  request(envelope: Record<string, unknown> & { id: string }, timeoutMs: number): Promise<DebugResult> {
    if (this.disposed) return Promise.resolve({ ok: false, error: "connection is closed" });
    if (this.pending.has(envelope.id)) return Promise.resolve({ ok: false, error: "request id is already pending" });
    return new Promise(resolve => {
      const timer = setTimeout(() => {
        this.finish(envelope.id, { ok: false, error: `timeout after ${timeoutMs}ms` });
        if (!this.pending.size) this.disconnect("connection timed out");
      }, timeoutMs);
      this.pending.set(envelope.id, { envelope, resolve, timer });
      try {
        const socket = this.connect();
        if (socket.readyState === WebSocket.OPEN) this.send(socket, envelope);
      } catch (error) {
        this.disconnect(`ws error (is the Ox Host running?): ${(error as Error).message}`);
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
      for (const { envelope } of this.pending.values()) this.send(socket, envelope);
    };
    socket.onerror = (event: Event) => {
      if (this.socket === socket) this.disconnect(`ws error (is the Ox Host running?): ${String((event as ErrorEvent).message ?? event)}`);
    };
    socket.onclose = () => {
      if (this.socket === socket) this.disconnect("ws closed before result");
    };
    socket.onmessage = event => {
      if (this.socket === socket) this.receive(event);
    };
    return socket;
  }

  private send(socket: WebSocket, envelope: Record<string, unknown> & { id: string }): void {
    try {
      socket.send(JSON.stringify(envelope));
    } catch (error) {
      this.finish(envelope.id, { ok: false, error: `ws send failed: ${(error as Error).message}` });
    }
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
    this.finish(message.id, message.ok ? message : { ...message, ok: false, error: String(message.error ?? "unknown") });
  }

  private finish(id: string, result: DebugResult): void {
    const pending = this.pending.get(id);
    if (!pending) return;
    clearTimeout(pending.timer);
    this.pending.delete(id);
    pending.resolve(result);
  }

  private disconnect(error: string): void {
    const socket = this.socket;
    this.socket = undefined;
    for (const id of this.pending.keys()) this.finish(id, { ok: false, error });
    socket?.close();
  }
}
