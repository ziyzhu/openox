import { callProfile } from "./profile-rpc.ts";

export type InvokeRequest = {
  domain: string;
  action: string;
  args: unknown;
  approved?: boolean;
  session?: { id: string; label: string; url: string };
  pageUrl?: string;
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

export interface ProfileServiceRuntime {
  status(timeoutMs: number): Promise<Record<string, unknown>>;
  invoke(request: InvokeRequest): Promise<Record<string, unknown>>;
  evaluate(request: EvaluateRequest): Promise<Record<string, unknown>>;
  reload(request: ReloadRequest): Promise<Record<string, unknown>>;
  refreshAuth(request: ReloadRequest): Promise<Record<string, unknown>>;
  sync(timeoutMs: number): Promise<Record<string, unknown>>;
}

class WebSocketProfileServiceRuntime implements ProfileServiceRuntime {
  private readonly endpoint?: string;

  constructor(endpoint?: string) {
    this.endpoint = endpoint;
  }

  status(timeoutMs: number) { return callProfile("services.list", {}, timeoutMs, this.endpoint); }

  invoke(request: InvokeRequest) {
    return callProfile("services.invoke", { domain: request.domain, action: request.action, args: request.args,
      ...(request.approved === undefined ? {} : { approve: request.approved }),
      ...(request.session === undefined ? {} : { session: request.session }),
      ...(request.pageUrl === undefined ? {} : { pageUrl: request.pageUrl }),
    }, request.timeoutMs, this.endpoint);
  }

  evaluate(request: EvaluateRequest) {
    return callProfile("services.evaluate", { domain: request.domain, script: request.script }, request.timeoutMs, this.endpoint);
  }

  reload(request: ReloadRequest) { return callProfile("services.reload", { domain: request.domain }, request.timeoutMs, this.endpoint); }

  refreshAuth(request: ReloadRequest) { return callProfile("services.refreshAuth", { domain: request.domain }, request.timeoutMs, this.endpoint); }

  sync(timeoutMs: number) { return callProfile("services.sync", {}, timeoutMs, this.endpoint); }
}

export function createProfileServiceRuntime(endpoint?: string): ProfileServiceRuntime {
  return new WebSocketProfileServiceRuntime(endpoint);
}
