import { type DebugResult } from "../debug-ws.ts";
import { withRepository } from "../repositories.ts";
import {
  type AuthRequest,
  type BotControlRequest,
  type EvaluateRequest,
  type InvokeRequest,
  type OpenRequest,
  type ReloadRequest,
  type ServiceRuntime,
} from "../service-runtime.ts";
import { ChromeBrowser } from "./browser.ts";
import { authenticateService, completeBotControl } from "./handoff.ts";
import { withServiceLock } from "./lock.ts";
import { ChromeServiceSession } from "./service.ts";

export class ChromeServiceRuntime implements ServiceRuntime {
  readonly name = "chrome";

  constructor(private readonly repositoryOrigin?: string) {}

  async sessions(timeoutMs: number): Promise<DebugResult> {
    return this.result(async () => {
      const browser = await ChromeBrowser.connect({ launch: false, timeoutMs });
      if (!browser) return { sessions: [], browser: "stopped" };
      try {
        return { sessions: await ChromeServiceSession.sessions(browser), browser: "running" };
      } finally {
        browser.close();
      }
    });
  }

  async status(timeoutMs: number): Promise<DebugResult> {
    return this.result(async () => {
      const browser = await ChromeBrowser.connect({ launch: false, timeoutMs });
      if (!browser) return { services: [], browser: "stopped" };
      try {
        return { services: await ChromeServiceSession.snapshots(browser), browser: "running" };
      } finally {
        browser.close();
      }
    });
  }

  async invoke(request: InvokeRequest): Promise<DebugResult> {
    return this.withService(request.domain, request.timeoutMs, request.sessionId, async (service) => ({
      value: await service.invoke(request.action, request.args, request.approved === true, request.timeoutMs),
    }));
  }

  async evaluate(request: EvaluateRequest): Promise<DebugResult> {
    return this.withService(request.domain, request.timeoutMs, request.sessionId, async (service) => ({
      value: await service.evaluate(request.script, request.timeoutMs),
    }));
  }

  async reload(request: ReloadRequest): Promise<DebugResult> {
    return this.withService(request.domain, request.timeoutMs, request.sessionId, async (service) => ({
      value: await service.reload(request.timeoutMs),
    }));
  }

  async open(request: OpenRequest): Promise<DebugResult> {
    return this.withService(request.domain, request.timeoutMs, request.sessionId, async (service) => ({
      value: {
        domain: request.domain,
        url: await service.activate(),
      },
    }));
  }

  async authenticate(request: AuthRequest): Promise<DebugResult> {
    return this.withBrowserService(request.domain, request.timeoutMs, request.sessionId, async (browser, service) => ({
      value: await authenticateService(browser, service, request.timeoutMs),
    }));
  }

  async botControl(request: BotControlRequest): Promise<DebugResult> {
    return this.withBrowserService(request.domain, request.timeoutMs, request.sessionId, async (browser, service) => ({
      value: await completeBotControl(browser, service, request.args, request.timeoutMs),
    }));
  }

  async sync(timeoutMs: number): Promise<DebugResult> {
    return this.result(async () => {
      return withRepository(this.origin(), async (_, repository) => {
        const browser = await ChromeBrowser.connect({ launch: false, timeoutMs });
        if (!browser) return { head: "repository", services: repository.services.length, changed: [] };
        try {
          const changed = await ChromeServiceSession.invalidateAll(browser);
          return { head: "repository", services: repository.services.length, changed };
        } finally {
          browser.close();
        }
      });
    });
  }

  private async withService(
    domain: string,
    timeoutMs: number,
    sessionId: string | undefined,
    operation: (service: ChromeServiceSession) => Promise<Record<string, unknown>>,
  ): Promise<DebugResult> {
    return this.withBrowserService(domain, timeoutMs, sessionId, async (_, service) => operation(service));
  }

  private async withBrowserService(
    domain: string,
    timeoutMs: number,
    sessionId: string | undefined,
    operation: (browser: ChromeBrowser, service: ChromeServiceSession) => Promise<Record<string, unknown>>,
  ): Promise<DebugResult> {
    return this.result(async () => {
      return withRepository(this.origin(), async (repositoryRoot, repository) => {
        if (!repository.services.includes(`web:${domain}`)) throw new Error(`repository does not contain web:${domain}`);
        const browser = await ChromeBrowser.connect({ timeoutMs });
        if (!browser) throw new Error("Chrome is not running");
        try {
          return await withServiceLock(browser.profileDir, domain, timeoutMs, async () => {
            const service = await ChromeServiceSession.open(browser, domain, timeoutMs, sessionId, repositoryRoot);
            return await operation(browser, service);
          });
        } finally {
          browser.close();
        }
      });
    });
  }

  private origin(): string {
    if (!this.repositoryOrigin) throw new Error("Chrome service commands require --repository <path-or-url>");
    return this.repositoryOrigin;
  }

  private async result(operation: () => Promise<Record<string, unknown>>): Promise<DebugResult> {
    try {
      return { ok: true, ...await operation() };
    } catch (error) {
      return { ok: false, error: String((error as Error)?.message ?? error) };
    }
  }
}
