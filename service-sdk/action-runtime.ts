import type { ActionInstaller } from "./action.ts";

type CaptureRegistration = {
  pattern: RegExp;
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timeout: ReturnType<typeof setTimeout>;
};

type CaptureWindow = Window & {
  XMLHttpRequest?: {
    prototype: XMLHttpRequest;
  };
  oxFetchCapture?: (
    pattern: RegExp,
    options?: { timeoutMs?: number; replayLatest?: boolean },
  ) => Promise<unknown>;
};

type RecentCapture = {
  url: string;
  value: Promise<unknown>;
};

const patternMatches = (pattern: RegExp, value: string): boolean => {
  pattern.lastIndex = 0;
  const matched = pattern.test(value);
  pattern.lastIndex = 0;
  return matched;
};

export function installFetchCapture(target: CaptureWindow): void {
  const registrations = new Set<CaptureRegistration>();
  const recent: RecentCapture[] = [];

  const matching = (url: string) =>
    Array.from(registrations).filter((registration) => patternMatches(registration.pattern, url));

  const settle = (matched: CaptureRegistration[], result: { value: unknown } | { error: Error }) => {
    for (const registration of matched) {
      if (!registrations.delete(registration)) continue;
      clearTimeout(registration.timeout);
      if ("error" in result) registration.reject(result.error);
      else registration.resolve(result.value);
    }
  };

  const canReplay = (url: string) => {
    try {
      const page = new URL(target.location.href);
      const request = new URL(url, page);
      return request.hostname === page.hostname && /^\/(?:api|web_api)\//.test(request.pathname);
    } catch {
      return false;
    }
  };

  const capture = (url: string, read: () => Promise<unknown>) => {
    const matched = matching(url);
    const replayable = canReplay(url);
    if (matched.length === 0 && !replayable) return;
    const value = read();
    if (replayable) {
      const entry = { url, value };
      recent.push(entry);
      while (recent.length > 32) recent.shift();
      void value.catch(() => {
        const index = recent.indexOf(entry);
        if (index >= 0) recent.splice(index, 1);
      });
    }
    if (matched.length === 0) return;
    void value.then(
      (value) => settle(matched, { value }),
      (error) => settle(matched, {
        error: new Error(`captured ${url} returned invalid JSON: ${String((error as Error)?.message ?? error)}`),
      }),
    );
  };

  target.oxFetchCapture = (pattern, options) => {
    if (options?.replayLatest) {
      for (let index = recent.length - 1; index >= 0; index--) {
        if (patternMatches(pattern, recent[index].url)) return recent[index].value;
      }
    }
    return new Promise((resolve, reject) => {
      const timeoutMs = options?.timeoutMs ?? 10000;
      const registration = {} as CaptureRegistration;
      registration.pattern = pattern;
      registration.resolve = resolve;
      registration.reject = reject;
      registration.timeout = setTimeout(() => {
        if (!registrations.delete(registration)) return;
        reject(new Error(`fetch capture timed out after ${timeoutMs}ms for ${pattern}`));
      }, timeoutMs);
      registrations.add(registration);
    });
  };
  const originalFetch = target.fetch.bind(target);
  target.fetch = ((input: RequestInfo | URL, init?: RequestInit) =>
    originalFetch(input, init).then((response) => {
      const url = input instanceof Request ? input.url : String(input);
      capture(url, () => response.clone().json());
      return response;
    })) as typeof target.fetch;

  const XHR = target.XMLHttpRequest;
  if (!XHR) return;
  const urls = new WeakMap<XMLHttpRequest, string>();
  const originalOpen = XHR.prototype.open;
  const originalSend = XHR.prototype.send;

  XHR.prototype.open = function (this: XMLHttpRequest, ...args: any[]) {
    urls.set(this, String(args[1] ?? ""));
    return (originalOpen as any).apply(this, args);
  } as typeof XHR.prototype.open;

  XHR.prototype.send = function (this: XMLHttpRequest, ...args: any[]) {
    this.addEventListener("loadend", () => {
      const url = urls.get(this) ?? this.responseURL;
      capture(url, async () => {
        if (this.responseType === "json") return this.response;
        return JSON.parse(this.responseText);
      });
    }, { once: true });
    return (originalSend as any).apply(this, args);
  } as typeof XHR.prototype.send;
}

export function installService(domain: string, installer: ActionInstaller): void {
  installFetchCapture(window);
  const log = (msg: string) => {
    try {
      (window as any).webkit?.messageHandlers?.oxConsole?.postMessage({
        level: "log",
        msg: `[service:${domain}] ${msg}`,
      });
    } catch {}
  };

  const retryFetch = async (
    input: RequestInfo | string,
    init?: RequestInit,
    opts?: { retries?: number; delay?: number; factor?: number },
  ): Promise<Response> => {
    const retries = opts?.retries ?? 3;
    const delay = opts?.delay ?? 400;
    const factor = opts?.factor ?? 2;
    const url = typeof input === "string" ? input : input.url;
    for (let attempt = 0; ; attempt++) {
      try {
        const response = await window.fetch(input, init);
        const retryable = response.status === 408 || response.status === 429
          || (response.status >= 500 && response.status <= 599);
        if (response.ok || !retryable || attempt >= retries) return response;
        log(`retryFetch: status ${response.status}, attempt ${attempt + 1}/${retries}, url=${url}`);
      } catch (error) {
        const message = String((error as Error)?.message ?? "");
        const retryable = message.includes("Load failed")
          || message.includes("NetworkError")
          || message.includes("Failed to fetch");
        if (!retryable || attempt >= retries) throw error;
        log(`retryFetch: network ${JSON.stringify(message)}, attempt ${attempt + 1}/${retries}, url=${url}`);
      }
      await new Promise((resolve) => setTimeout(resolve, delay * Math.pow(factor, attempt)));
    }
  };

  const actions = new Map<string, (args: any) => unknown | Promise<unknown>>();
  const action = (name: string, definition: { invoke: (args: any) => unknown | Promise<unknown> }) => {
    if (actions.has(name)) throw new Error(`duplicate action: ${name}`);
    if (typeof definition?.invoke !== "function") throw new Error(`action ${name} has no invoke function`);
    actions.set(name, definition.invoke);
  };

  try {
    installer({ action, retryFetch, log });
  } catch (error) {
    log(`service installer threw: ${String((error as Error)?.stack ?? (error as Error)?.message ?? error)}`);
    throw error;
  }

  const invoke = async (name: string, args: any) => {
    const handler = actions.get(name);
    if (!handler) throw new Error(`unknown action: ${name}`);
    try {
      return await handler(args ?? {});
    } catch (error) {
      log(`action ${JSON.stringify(name)} threw: ${String((error as Error)?.stack ?? (error as Error)?.message ?? error)}`);
      throw new Error(`action ${JSON.stringify(name)} failed: ${String((error as Error)?.message ?? error)}`);
    }
  };

  const runtime = {
    callServiceAction: (name: string, args: any) => invoke(name, args),
  };
  (window as any).ox = runtime;
}
