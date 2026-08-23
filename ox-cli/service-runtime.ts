import { runOnce, type DebugResult } from "./debug-ws.ts";
import { ChromeServiceRuntime } from "./chrome/runtime.ts";

export type RuntimeName = "ios" | "chrome";

export type RuntimeSession = {
  id: string;
  runtime: RuntimeName;
  kind: "service" | "tab";
  domain: string | null;
  title: string;
  url: string | null;
};

export type InvokeRequest = {
  domain: string;
  action: string;
  args: unknown;
  approved?: boolean;
  timeoutMs: number;
  sessionId?: string;
};

export type EvaluateRequest = {
  domain: string;
  script: string;
  timeoutMs: number;
  sessionId?: string;
};

export type ReloadRequest = {
  domain: string;
  timeoutMs: number;
  sessionId?: string;
};

export type OpenRequest = {
  domain: string;
  timeoutMs: number;
  sessionId?: string;
};

export type AuthRequest = {
  domain: string;
  timeoutMs: number;
  sessionId?: string;
};

export type BotControlRequest = {
  domain: string;
  args: Record<string, unknown>;
  timeoutMs: number;
  sessionId?: string;
};

export interface ServiceRuntime {
  readonly name: RuntimeName;
  sessions(timeoutMs: number): Promise<DebugResult>;
  status(timeoutMs: number): Promise<DebugResult>;
  invoke(request: InvokeRequest): Promise<DebugResult>;
  evaluate(request: EvaluateRequest): Promise<DebugResult>;
  reload(request: ReloadRequest): Promise<DebugResult>;
  open(request: OpenRequest): Promise<DebugResult>;
  authenticate(request: AuthRequest): Promise<DebugResult>;
  botControl(request: BotControlRequest): Promise<DebugResult>;
  sync(timeoutMs: number): Promise<DebugResult>;
}

class IOSServiceRuntime implements ServiceRuntime {
  readonly name = "ios";

  async sessions(timeoutMs: number): Promise<DebugResult> {
    const result = await runOnce({ kind: "list-services", id: crypto.randomUUID() }, timeoutMs);
    if (!result.ok) return result;
    const services = Array.isArray(result.services) ? result.services as Array<Record<string, unknown>> : [];
    const sessions: RuntimeSession[] = services.flatMap((service) => {
      if (typeof service.domain !== "string") return [];
      const page = service.page && typeof service.page === "object"
        ? service.page as Record<string, unknown>
        : undefined;
      return [{
        id: service.domain,
        runtime: "ios",
        kind: "service",
        domain: service.domain,
        title: typeof service.title === "string" ? service.title : "",
        url: page && typeof page.url === "string" ? safeSessionUrl(page.url) : null,
      } satisfies RuntimeSession];
    }).sort((left, right) => left.id.localeCompare(right.id));
    return { ok: true, sessions };
  }

  status(timeoutMs: number): Promise<DebugResult> {
    return runOnce({ kind: "list-services", id: crypto.randomUUID() }, timeoutMs);
  }

  invoke(request: InvokeRequest): Promise<DebugResult> {
    const invalid = this.validateSession(request.domain, request.sessionId);
    if (invalid) return Promise.resolve(invalid);
    const envelope: Record<string, unknown> & { id: string } = {
      kind: "invoke-action",
      id: crypto.randomUUID(),
      domain: request.domain,
      action: request.action,
      args: request.args,
    };
    if (request.approved !== undefined) envelope.approve = request.approved;
    return runOnce(envelope, request.timeoutMs);
  }

  evaluate(request: EvaluateRequest): Promise<DebugResult> {
    const invalid = this.validateSession(request.domain, request.sessionId);
    if (invalid) return Promise.resolve(invalid);
    return runOnce({
      kind: "evaluate",
      id: crypto.randomUUID(),
      domain: request.domain,
      script: request.script,
    }, request.timeoutMs);
  }

  reload(request: ReloadRequest): Promise<DebugResult> {
    const invalid = this.validateSession(request.domain, request.sessionId);
    if (invalid) return Promise.resolve(invalid);
    return runOnce({
      kind: "reload-service",
      id: crypto.randomUUID(),
      domain: request.domain,
    }, request.timeoutMs);
  }

  open(): Promise<DebugResult> {
    return Promise.resolve({ ok: false, error: "Opening a service page requires --runtime chrome" });
  }

  authenticate(): Promise<DebugResult> {
    return Promise.resolve({ ok: false, error: "Sign in through the running iOS app" });
  }

  botControl(): Promise<DebugResult> {
    return Promise.resolve({ ok: false, error: "Complete bot control through the running iOS app" });
  }

  sync(timeoutMs: number): Promise<DebugResult> {
    return runOnce({ kind: "sync-mono-repository", id: crypto.randomUUID() }, timeoutMs);
  }

  private validateSession(domain: string, sessionId: string | undefined): DebugResult | undefined {
    if (!sessionId || sessionId === domain) return undefined;
    return { ok: false, error: `iOS session ${sessionId} does not match service ${domain}` };
  }
}

export function createServiceRuntime(name: RuntimeName, repository?: string): ServiceRuntime {
  return name === "ios" ? new IOSServiceRuntime() : new ChromeServiceRuntime(repository);
}

function safeSessionUrl(value: string): string | null {
  try {
    const url = new URL(value);
    url.search = "";
    url.hash = "";
    return url.toString();
  } catch {
    return null;
  }
}
