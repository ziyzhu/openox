import {
  validateAgainstSchema,
  readWebService,
  SIGN_IN_STATE_ACTION_ID,
  type ServiceAction,
  type ServiceManifest,
} from "../service-manifest.ts";
import { chromeDiagnostic } from "../lib.ts";
import { type RuntimeSession } from "../service-runtime.ts";
import { type ChromeBrowser } from "./browser.ts";
import { CdpError } from "./cdp.ts";
import { readChromeMetadata, writeChromeMetadata } from "./metadata.ts";

type TargetInfo = {
  targetId: string;
  type: string;
  url: string;
  title: string;
};

type RuntimeRemoteObject = {
  type: string;
  subtype?: string;
  value?: unknown;
  description?: string;
};

type RuntimeEvaluateResult = {
  result: RuntimeRemoteObject;
  exceptionDetails?: {
    text?: string;
    exception?: RuntimeRemoteObject;
  };
};

export type ChromeServiceSnapshot = {
  domain: string;
  phase: string;
  navigation: string;
  activeInvocations: number;
  queuedInvocations: number;
  pendingEvaluations: number;
  auth: string;
  page: {
    url: string;
    title: string;
    isLoading: boolean;
  } | null;
};

export class ChromeServiceSession {
  private constructor(
    readonly domain: string,
    readonly manifest: ServiceManifest,
    readonly actionsSource: string,
    readonly bundleHash: string,
    readonly targetId: string,
    readonly sessionId: string,
    private readonly browser: ChromeBrowser,
  ) {}

  static async open(
    browser: ChromeBrowser,
    domain: string,
    timeoutMs: number,
    selectedTargetId?: string,
    repositoryRoot?: string,
  ): Promise<ChromeServiceSession> {
    if (!repositoryRoot) throw new Error("Chrome service commands require --repository <path-or-url>");
    const built = await readWebService(repositoryRoot, domain);
    if (!built.manifest.baseUrl) throw new Error(`service ${domain} has no start URL`);
    const bundleHash = new Bun.CryptoHasher("sha256").update(built.actions).digest("hex").slice(0, 16);
    const metadata = await readChromeMetadata(browser.profileDir, browser.endpoint.path);
    const targets = await browser.cdp.send<{ targetInfos: TargetInfo[] }>("Target.getTargets");
    const record = metadata.services[domain];
    const selectedTarget = selectedTargetId
      ? targets.targetInfos.find((candidate) => candidate.targetId === selectedTargetId && candidate.type === "page")
      : undefined;
    if (selectedTargetId && !selectedTarget) throw new Error(`unknown Chrome session: ${selectedTargetId}`);
    if (selectedTarget && !isServiceUrl(selectedTarget.url, domain, false)) {
      throw new Error(`Chrome session ${selectedTargetId} is not a ${domain} page`);
    }
    let target = selectedTarget ?? (record && record.bundleHash === bundleHash
      ? targets.targetInfos.find((candidate) => candidate.targetId === record.targetId && candidate.type === "page")
      : undefined);
    if (record && !target) delete metadata.services[domain];
    if (target && !isServiceUrl(target.url, domain)) {
      await browser.cdp.send("Target.closeTarget", { targetId: target.targetId });
      delete metadata.services[domain];
      target = undefined;
    }
    let created = false;
    if (!target) {
      const result = await browser.cdp.send<{ targetId: string }>("Target.createTarget", {
        url: "about:blank",
        background: true,
      });
      target = { targetId: result.targetId, type: "page", url: "about:blank", title: "" };
      created = true;
    }
    const attached = await browser.cdp.send<{ sessionId: string }>("Target.attachToTarget", {
      targetId: target.targetId,
      flatten: true,
    });
    const service = new ChromeServiceSession(
      domain,
      built.manifest,
      built.actions,
      bundleHash,
      target.targetId,
      attached.sessionId,
      browser,
    );
    chromeDiagnostic(`service target domain=${domain} disposition=${created ? "created" : "reused"}`);
    await service.prepare(created, timeoutMs);
    if (!selectedTargetId) {
      metadata.services[domain] = { targetId: target.targetId, bundleHash };
      await writeChromeMetadata(browser.profileDir, metadata);
    }
    return service;
  }

  static async sessions(browser: ChromeBrowser): Promise<RuntimeSession[]> {
    const metadata = await readChromeMetadata(browser.profileDir, browser.endpoint.path);
    const targets = await browser.cdp.send<{ targetInfos: TargetInfo[] }>("Target.getTargets");
    const domains = new Map(Object.entries(metadata.services).map(([domain, record]) => [record.targetId, domain]));
    return targets.targetInfos
      .filter(isTargetableTab)
      .sort((left, right) => left.targetId.localeCompare(right.targetId))
      .map((target) => ({
        id: target.targetId,
        runtime: "chrome",
        kind: "tab",
        domain: domains.get(target.targetId) ?? null,
        title: target.title,
        url: safePageUrl(target.url),
      }));
  }

  static async snapshots(browser: ChromeBrowser): Promise<ChromeServiceSnapshot[]> {
    const metadata = await readChromeMetadata(browser.profileDir, browser.endpoint.path);
    const targets = await browser.cdp.send<{ targetInfos: TargetInfo[] }>("Target.getTargets");
    const targetById = new Map(targets.targetInfos.map((target) => [target.targetId, target]));
    const snapshots: ChromeServiceSnapshot[] = [];
    for (const [domain, record] of Object.entries(metadata.services).sort(([a], [b]) => a.localeCompare(b))) {
      const target = targetById.get(record.targetId);
      if (!target) continue;
      snapshots.push({
        domain,
        phase: "active",
        navigation: "ready",
        activeInvocations: 0,
        queuedInvocations: 0,
        pendingEvaluations: 0,
        auth: "unknown",
        page: {
          url: safePageUrl(target.url),
          title: target.title,
          isLoading: false,
        },
      });
    }
    return snapshots;
  }

  static async invalidateAll(browser: ChromeBrowser): Promise<string[]> {
    const metadata = await readChromeMetadata(browser.profileDir, browser.endpoint.path);
    const targets = await browser.cdp.send<{ targetInfos: TargetInfo[] }>("Target.getTargets");
    const live = new Set(targets.targetInfos.map((target) => target.targetId));
    const changed = Object.keys(metadata.services).sort();
    for (const record of Object.values(metadata.services)) {
      if (!live.has(record.targetId)) continue;
      await browser.cdp.send("Target.closeTarget", { targetId: record.targetId }).catch(() => {});
    }
    metadata.services = {};
    await writeChromeMetadata(browser.profileDir, metadata);
    return changed;
  }

  async invoke(actionId: string, args: unknown, approved: boolean, timeoutMs: number): Promise<unknown> {
    const action = this.manifest.actions.find((candidate: ServiceAction) => candidate.id === actionId);
    const name = `${this.domain}:${actionId}`;
    if (!action) throw new Error(`unknown action "${name}"`);
    const input = validateAgainstSchema(action.inputSchema, args, this.manifest.$defs);
    if (!input.ok) throw new Error(`action "${name}" input is invalid: ${input.errors.join("; ")}`);
    if (action.requireApproval && !approved) throw new Error(`action "${name}" requires explicit --approve`);
    if (action.requireAuth) await this.requireAuthentication(name, timeoutMs);
    const actionBaseUrl = resolveActionBaseUrl(action, args);
    if (actionBaseUrl && !sameUrl(actionBaseUrl, await this.currentUrl())) await this.navigate(actionBaseUrl, timeoutMs);
    const value = await this.invokeRaw(actionId, args, timeoutMs);
    const output = validateAgainstSchema(action.outputSchema, value, this.manifest.$defs);
    if (!output.ok) throw new Error(`action "${name}" returned invalid output: ${output.errors.join("; ")}`);
    return value;
  }

  async evaluate(script: string, timeoutMs: number): Promise<unknown> {
    await this.assertServicePage();
    return this.evaluateExpression(`(async () => { ${script}\n})()`, timeoutMs);
  }

  async reload(timeoutMs: number): Promise<string> {
    const loaded = this.waitForLoad(timeoutMs);
    await this.browser.cdp.send("Page.reload", {}, this.sessionId, timeoutMs);
    await loaded;
    await this.assertServicePage();
    return await this.currentUrl();
  }

  async activate(): Promise<string> {
    await this.browser.cdp.send("Target.activateTarget", { targetId: this.targetId });
    return safePageUrl(await this.currentUrl());
  }

  private async prepare(created: boolean, timeoutMs: number): Promise<void> {
    await Promise.all([
      this.browser.cdp.send("Page.enable", {}, this.sessionId, timeoutMs),
      this.browser.cdp.send("Runtime.enable", {}, this.sessionId, timeoutMs),
    ]);
    await this.browser.cdp.send("Page.addScriptToEvaluateOnNewDocument", {
      source: this.actionsSource,
    }, this.sessionId, timeoutMs);
    if (created) {
      await this.navigate(this.manifest.baseUrl!, timeoutMs);
    } else {
      await this.evaluateExpression(this.actionsSource, timeoutMs);
      await this.assertServicePage();
    }
  }

  private async navigate(url: string, timeoutMs: number): Promise<void> {
    const loaded = this.waitForLoad(timeoutMs);
    const result = await this.browser.cdp.send<{ errorText?: string }>("Page.navigate", { url }, this.sessionId, timeoutMs);
    if (result.errorText) throw new Error(`service navigation failed: ${result.errorText}`);
    await loaded;
    await this.assertServicePage();
  }

  private waitForLoad(timeoutMs: number): Promise<void> {
    return new Promise((resolve, reject) => {
      let settled = false;
      const stop = this.browser.cdp.on("Page.loadEventFired", () => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        stop();
        resolve();
      }, this.sessionId);
      const timeout = setTimeout(() => {
        if (settled) return;
        settled = true;
        stop();
        reject(new Error(`service navigation timed out after ${timeoutMs}ms`));
      }, timeoutMs);
    });
  }

  private async requireAuthentication(name: string, timeoutMs: number): Promise<void> {
    const probe = this.manifest.actions.find((action) => action.id === SIGN_IN_STATE_ACTION_ID);
    if (!probe) throw new Error(`action "${name}" has no authentication state action`);
    const state = await this.invokeRaw(SIGN_IN_STATE_ACTION_ID, {}, timeoutMs) as { signedIn?: unknown };
    if (state?.signedIn !== true) {
      throw new Error(`action "${name}" requires sign-in — run ox --runtime chrome service auth ${this.domain}`);
    }
  }

  private async invokeRaw(actionId: string, args: unknown, timeoutMs: number): Promise<unknown> {
    await this.assertServicePage();
    const expression = `window.ox.callServiceAction(${JSON.stringify(actionId)}, ${JSON.stringify(args ?? {})})`;
    return this.evaluateExpression(expression, timeoutMs);
  }

  private async evaluateExpression(expression: string, timeoutMs: number): Promise<unknown> {
    let response: RuntimeEvaluateResult;
    try {
      response = await this.browser.cdp.send<RuntimeEvaluateResult>("Runtime.evaluate", {
        expression,
        awaitPromise: true,
        returnByValue: true,
        userGesture: true,
      }, this.sessionId, timeoutMs);
    } catch (error) {
      if (error instanceof CdpError && /context|target|session|navigation/i.test(error.message)) {
        throw new Error("service page navigated while the action was running");
      }
      throw error;
    }
    if (response.exceptionDetails) {
      const description = response.exceptionDetails.exception?.description
        ?? response.exceptionDetails.text
        ?? "JavaScript evaluation failed";
      throw new Error(description);
    }
    return response.result.value;
  }

  private async assertServicePage(): Promise<void> {
    const url = await this.currentUrl();
    if (!isServiceUrl(url, this.domain)) throw new Error("service page is off-domain; refusing to invoke");
  }

  private async currentUrl(): Promise<string> {
    const value = await this.evaluateExpression("location.href", 5_000);
    return typeof value === "string" ? value : "";
  }
}

function isServiceUrl(value: string, domain: string, allowBlank = true): boolean {
  if (value === "about:blank") return allowBlank;
  try {
    const host = new URL(value).hostname.toLowerCase();
    return host === domain || host.endsWith(`.${domain}`);
  } catch {
    return false;
  }
}

function isTargetableTab(target: TargetInfo): boolean {
  if (target.type !== "page") return false;
  try {
    const protocol = new URL(target.url).protocol;
    return protocol === "http:" || protocol === "https:";
  } catch {
    return false;
  }
}

function resolveActionBaseUrl(action: ServiceAction, args: unknown): string | undefined {
  if (!action.baseUrl) return undefined;
  const input = typeof args === "object" && args !== null && !Array.isArray(args)
    ? args as Record<string, unknown>
    : {};
  const url = new URL(action.baseUrl);
  for (const [name, value] of [...url.searchParams.entries()]) {
    const match = value.match(/^\{([A-Za-z_][A-Za-z0-9_]*)\}$/);
    if (!match) continue;
    const replacement = input[match[1]!];
    if (typeof replacement === "string") url.searchParams.set(name, replacement);
    else url.searchParams.delete(name);
  }
  return url.toString();
}

function sameUrl(left: string, right: string): boolean {
  try {
    return new URL(left).toString() === new URL(right).toString();
  } catch {
    return false;
  }
}

function safePageUrl(value: string): string {
  try {
    const url = new URL(value);
    url.search = "";
    url.hash = "";
    return url.toString();
  } catch {
    return value === "about:blank" ? value : "";
  }
}
