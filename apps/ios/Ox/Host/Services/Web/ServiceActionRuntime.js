(() => {
  const abiVersion = 1;

  const cookie = name => {
    const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const match = document.cookie.match(new RegExp(`(?:^|;\\s*)${escaped}=([^;]*)`));
    if (!match) return null;
    try {
      return decodeURIComponent(match[1]);
    } catch {
      return match[1];
    }
  };

  const cleanText = value => String(value ?? "").replace(/\s+/g, " ").trim();

  const pageCursor = (value, firstPage) =>
    Math.max(firstPage, Number.parseInt(value ?? String(firstPage), 10) || firstPage);

  const lib = Object.freeze({ cookie, cleanText, pageCursor });

  const patternMatches = (pattern, value) => {
    pattern.lastIndex = 0;
    const matched = pattern.test(value);
    pattern.lastIndex = 0;
    return matched;
  };

  const installFetchCapture = target => {
    const registrations = new Set();
    const recent = [];
    const matching = url => [...registrations].filter(registration => patternMatches(registration.pattern, url));
    const settle = (matched, result) => {
      for (const registration of matched) {
        if (!registrations.delete(registration)) continue;
        clearTimeout(registration.timeout);
        if (result.error) registration.reject(result.error);
        else registration.resolve(result.value);
      }
    };
    const canReplay = url => {
      try {
        const page = new URL(target.location.href);
        const request = new URL(url, page);
        return request.hostname === page.hostname && /^\/(?:api|web_api)\//.test(request.pathname);
      } catch {
        return false;
      }
    };
    const capture = (url, read) => {
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
        result => settle(matched, { value: result }),
        error => settle(matched, {
          error: new Error(`captured ${url} returned invalid JSON: ${String(error?.message ?? error)}`),
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
        const registration = { pattern, resolve, reject };
        registration.timeout = setTimeout(() => {
          if (!registrations.delete(registration)) return;
          reject(new Error(`fetch capture timed out after ${timeoutMs}ms for ${pattern}`));
        }, timeoutMs);
        registrations.add(registration);
      });
    };

    const originalFetch = target.fetch.bind(target);
    target.fetch = (input, init) => originalFetch(input, init).then(response => {
      const url = input instanceof Request ? input.url : String(input);
      capture(url, () => response.clone().json());
      return response;
    });

    const XHR = target.XMLHttpRequest;
    if (!XHR) return;
    const urls = new WeakMap();
    const originalOpen = XHR.prototype.open;
    const originalSend = XHR.prototype.send;
    XHR.prototype.open = function (...args) {
      urls.set(this, String(args[1] ?? ""));
      return originalOpen.apply(this, args);
    };
    XHR.prototype.send = function (...args) {
      this.addEventListener("loadend", () => {
        const url = urls.get(this) ?? this.responseURL;
        capture(url, async () => this.responseType === "json" ? this.response : JSON.parse(this.responseText));
      }, { once: true });
      return originalSend.apply(this, args);
    };
  };

  window.__openOxCreateServiceRuntime = domain => {
    installFetchCapture(window);
    const actions = new Map();
    let installed = false;
    const log = message => {
      try {
        window.webkit?.messageHandlers?.oxConsole?.postMessage({
          level: "log",
          msg: `[service:${domain}] ${message}`,
        });
      } catch {}
    };
    const retryFetch = async (input, init, options) => {
      const retries = options?.retries ?? 3;
      const delay = options?.delay ?? 400;
      const factor = options?.factor ?? 2;
      const url = typeof input === "string" ? input : input.url;
      for (let attempt = 0; ; attempt++) {
        try {
          const response = await window.fetch(input, init);
          const retryable = response.status === 408 || response.status === 429
            || (response.status >= 500 && response.status <= 599);
          if (response.ok || !retryable || attempt >= retries) return response;
          log(`retryFetch: status ${response.status}, attempt ${attempt + 1}/${retries}, url=${url}`);
        } catch (error) {
          const message = String(error?.message ?? "");
          const retryable = message.includes("Load failed")
            || message.includes("NetworkError")
            || message.includes("Failed to fetch");
          if (!retryable || attempt >= retries) throw error;
          log(`retryFetch: network ${JSON.stringify(message)}, attempt ${attempt + 1}/${retries}, url=${url}`);
        }
        await new Promise(resolve => setTimeout(resolve, delay * Math.pow(factor, attempt)));
      }
    };
    const action = (name, definition) => {
      if (installed) throw new Error("service installer has already completed");
      if (typeof name !== "string" || !name) throw new Error("action name must be a non-empty string");
      if (actions.has(name)) throw new Error(`duplicate action: ${name}`);
      if (typeof definition?.invoke !== "function") throw new Error(`action ${name} has no invoke function`);
      actions.set(name, definition.invoke);
    };
    const install = (version, installer) => {
      if (installed || actions.size > 0) throw new Error("service installer may run only once");
      if (version !== abiVersion) throw new Error(`unsupported service action ABI: ${version}`);
      if (typeof installer !== "function") throw new Error("service installer must be a function");
      try {
        const result = installer({ action, retryFetch, log, lib });
        if (result && typeof result.then === "function") throw new Error("service installer must be synchronous");
        installed = true;
      } catch (error) {
        actions.clear();
        log(`service installer threw: ${String(error?.stack ?? error?.message ?? error)}`);
        throw error;
      }
    };
    const callServiceAction = async (name, args = {}) => {
      if (!installed) throw new Error("service installer has not completed");
      const handler = actions.get(name);
      if (!handler) throw new Error(`unknown action: ${name}`);
      try {
        return await handler(args ?? {});
      } catch (error) {
        log(`action ${JSON.stringify(name)} threw: ${String(error?.stack ?? error?.message ?? error)}`);
        throw new Error(`action ${JSON.stringify(name)} failed: ${String(error?.message ?? error)}`);
      }
    };
    return { install, callServiceAction };
  };
})();
