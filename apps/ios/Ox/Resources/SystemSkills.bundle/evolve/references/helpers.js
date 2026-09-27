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

const retryFetch = async (input, init, options) => {
  const retries = options?.retries ?? 3;
  const delay = options?.delay ?? 400;
  const factor = options?.factor ?? 2;
  for (let attempt = 0; ; attempt++) {
    try {
      const response = await window.fetch(input, init);
      const retryable = response.status === 408 || response.status === 429
        || (response.status >= 500 && response.status <= 599);
      if (response.ok || !retryable || attempt >= retries) return response;
      console.log(`retryFetch: status ${response.status}, attempt ${attempt + 1}/${retries}`);
    } catch (error) {
      const message = String(error?.message ?? "");
      const retryable = message.includes("Load failed")
        || message.includes("NetworkError")
        || message.includes("Failed to fetch");
      if (!retryable || attempt >= retries) throw error;
      console.log(`retryFetch: network ${JSON.stringify(message)}, attempt ${attempt + 1}/${retries}`);
    }
    await new Promise(resolve => setTimeout(resolve, delay * Math.pow(factor, attempt)));
  }
};

const createFetchCapture = target => {
  const registrations = new Set();
  const recent = [];
  const patternMatches = (pattern, value) => {
    pattern.lastIndex = 0;
    const matched = pattern.test(value);
    pattern.lastIndex = 0;
    return matched;
  };
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
        error: new Error(`captured response returned invalid JSON: ${String(error?.message ?? error)}`),
      }),
    );
  };

  const waitForCapture = (pattern, options) => {
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

  if (typeof target.fetch === "function") {
    const originalFetch = target.fetch.bind(target);
    target.fetch = (input, init) => originalFetch(input, init).then(response => {
      const url = input instanceof Request ? input.url : String(input);
      capture(url, () => response.clone().json());
      return response;
    });
  }

  const XHR = target.XMLHttpRequest;
  if (!XHR) return waitForCapture;
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
  return waitForCapture;
};
