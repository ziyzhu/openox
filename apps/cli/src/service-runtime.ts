import { runOnce, type DebugResult } from "./debug-ws.ts";

export type InvokeRequest = {
  domain: string;
  action: string;
  args: unknown;
  approved?: boolean;
  timeoutMs: number;
};

export type EvaluateRequest = {
  domain: string;
  script: string;
  timeoutMs: number;
};

export type ReloadRequest = {
  domain: string;
  timeoutMs: number;
};

export interface HostServiceRuntime {
  status(timeoutMs: number): Promise<DebugResult>;
  invoke(request: InvokeRequest): Promise<DebugResult>;
  evaluate(request: EvaluateRequest): Promise<DebugResult>;
  reload(request: ReloadRequest): Promise<DebugResult>;
  sync(timeoutMs: number): Promise<DebugResult>;
}

class WebSocketHostServiceRuntime implements HostServiceRuntime {
  constructor(private readonly endpoint?: string) {}

  status(timeoutMs: number): Promise<DebugResult> {
    return runOnce({ kind: "list-services", id: crypto.randomUUID() }, timeoutMs, this.endpoint);
  }

  invoke(request: InvokeRequest): Promise<DebugResult> {
    const envelope: Record<string, unknown> & { id: string } = {
      kind: "invoke-action",
      id: crypto.randomUUID(),
      domain: request.domain,
      action: request.action,
      args: request.args,
    };
    if (request.approved !== undefined) envelope.approve = request.approved;
    return runOnce(envelope, request.timeoutMs, this.endpoint);
  }

  evaluate(request: EvaluateRequest): Promise<DebugResult> {
    return runOnce({
      kind: "evaluate",
      id: crypto.randomUUID(),
      domain: request.domain,
      script: request.script,
    }, request.timeoutMs, this.endpoint);
  }

  reload(request: ReloadRequest): Promise<DebugResult> {
    return runOnce({
      kind: "reload-service",
      id: crypto.randomUUID(),
      domain: request.domain,
    }, request.timeoutMs, this.endpoint);
  }

  sync(timeoutMs: number): Promise<DebugResult> {
    return runOnce({ kind: "sync-mono-repository", id: crypto.randomUUID() }, timeoutMs, this.endpoint);
  }
}

export function createHostServiceRuntime(endpoint?: string): HostServiceRuntime {
  return new WebSocketHostServiceRuntime(endpoint);
}
