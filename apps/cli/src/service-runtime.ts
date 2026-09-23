import { callHost } from "./host-rpc.ts";

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
  status(timeoutMs: number): Promise<Record<string, unknown>>;
  invoke(request: InvokeRequest): Promise<Record<string, unknown>>;
  evaluate(request: EvaluateRequest): Promise<Record<string, unknown>>;
  reload(request: ReloadRequest): Promise<Record<string, unknown>>;
  sync(timeoutMs: number): Promise<Record<string, unknown>>;
}

class WebSocketHostServiceRuntime implements HostServiceRuntime {
  constructor(private readonly endpoint?: string) {}

  status(timeoutMs: number) { return callHost("services.list", {}, timeoutMs, this.endpoint); }

  invoke(request: InvokeRequest) {
    return callHost("services.invoke", { domain: request.domain, action: request.action, args: request.args,
      ...(request.approved === undefined ? {} : { approve: request.approved }),
    }, request.timeoutMs, this.endpoint);
  }

  evaluate(request: EvaluateRequest) {
    return callHost("services.evaluate", { domain: request.domain, script: request.script }, request.timeoutMs, this.endpoint);
  }

  reload(request: ReloadRequest) { return callHost("services.reload", { domain: request.domain }, request.timeoutMs, this.endpoint); }

  sync(timeoutMs: number) { return callHost("services.sync", {}, timeoutMs, this.endpoint); }
}

export function createHostServiceRuntime(endpoint?: string): HostServiceRuntime {
  return new WebSocketHostServiceRuntime(endpoint);
}
