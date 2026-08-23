const DEFAULT_ENDPOINT = "ws://127.0.0.1:9876";

export type DebugResult =
  | ({ ok: true } & Record<string, unknown>)
  | { ok: false; error: string };

export type Result = DebugResult;

export function debugEndpoint(): string {
  const value = process.env.OX_DEBUG_ENDPOINT ?? DEFAULT_ENDPOINT;
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
      finish({ ok: false, error: `ws error (is the iOS app running on the sim?): ${message}` });
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
      finish(message.ok ? message : { ok: false, error: String(message.error ?? "unknown") });
    };
  });
}
