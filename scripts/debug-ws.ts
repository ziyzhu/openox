const DEFAULT_ENDPOINT = "ws://127.0.0.1:9876";

export type DebugResult =
  | ({ ok: true } & Record<string, unknown>)
  | { ok: false; error: string };

export type Result = DebugResult;

export type DebugPayload =
  | { kind: "invoke-action"; domain: string; action: string; args?: unknown; approve?: boolean }
  | { kind: "evaluate"; domain: string; script: string }
  | { kind: "reload-service"; domain: string }
  | { kind: "refresh-service-auth"; domain: string }
  | { kind: "list-services" }
  | { kind: "sync-mono-repository" }
  | { kind: "list-chats" }
  | { kind: "get-chat"; sessionId?: string }
  | { kind: "list-models" }
  | { kind: "get-logs" }
  | { kind: "get-transcript" }
  | { kind: "get-performance" }
  | { kind: "get-latest-response" }
  | { kind: "get-transcript-performance" }
  | { kind: "get-composer-formatting" }
  | { kind: "open-transcript-fixture"; turns: 200 | 400 }
  | { kind: "retain-baseline-sessions"; count: number }
  | { kind: "repository-gate"; domain: "save"; action: "hold" | "release" | "status" }
  | { kind: "replay-reducer"; fixtures: Array<{ name: string; turns: unknown[] }> }
  | { kind: "run-agent"; clientId: string; modelId: string; sessionId?: string; prompt?: string; historyOverride?: Array<{ user: string; assistant: Record<string, unknown> }> }
  | { kind: "virtual-machine-eval"; script: string; sessionId?: string }
  | {
    kind: "run-deadline-chat";
    prompt: string;
    delayMilliseconds: number;
    setupDelayMilliseconds?: number;
    answerDelayMilliseconds?: number;
    answers?: string[];
  }
  | { kind: "bootstrap-artifacts"; artifacts: Array<{ name: string; data: string }> }
  | { kind: "write-artifact"; name: string; data: string }
  | { kind: "export-website-data" }
  | { kind: "restore-website-data"; data: string }
  | { kind: "set-key"; clientId: string; key?: string }
  | { kind: "set-region"; region: "global" | "china" }
  | { kind: "set-attached-service"; domain?: string; domains?: string[] }
  | { kind: "set-composer-draft"; prompt: string }
  | { kind: "set-composer-marked-text"; prompt: string }
  | { kind: "set-pasteboard-image" }
  | { kind: "set-pasteboard-rich-text"; prompt: string }
  | { kind: "stage-shared-note"; prompt: string }
  | { kind: "set-edit-draft"; prompt: string };

type DebugRequest = Record<string, unknown> & { id: string };

function validPort(value: number): number {
  return Number.isInteger(value) && value > 0 && value <= 65535 ? value : 9876;
}

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
  envelope: DebugRequest,
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

export function runDebug(port: number, payload: DebugPayload, timeoutMs: number): Promise<DebugResult> {
  return runOnce({ ...payload, id: crypto.randomUUID() }, timeoutMs, `ws://127.0.0.1:${validPort(port)}`);
}
