(() => {
  // services/builtin/web/archive.ph/actions.ts
  var ORIGIN = "https://archive.ph";
  var CAPTURE_ID = /^[A-Za-z0-9]{5}$/;
  var install = ({ action, retryFetch }) => {
    const documentFrom = async (response, context) => {
      if (!response.ok)
        throw new Error(`${context}: HTTP ${response.status}`);
      return new DOMParser().parseFromString(await response.text(), "text/html");
    };
    const fetchDocument = async (url, context) => {
      const response = await retryFetch(url, { credentials: "include" });
      return documentFrom(response, context);
    };
    const normalizedUrl = (value) => {
      try {
        return new URL(value).href;
      } catch {
        return value;
      }
    };
    const captureIdFromUrl = (value) => {
      const pathname = new URL(value, ORIGIN).pathname;
      const id = pathname.split("/").filter(Boolean)[0] ?? "";
      return CAPTURE_ID.test(id) ? id : "";
    };
    const originalUrlFromDocument = (document) => {
      const canonical = document.querySelector('link[rel="canonical"]')?.href ?? "";
      const match = canonical.match(/\/\d{4}\.\d{2}\.\d{2}-\d{6}\/(https?:\/\/.*)$/);
      return match?.[1] ?? "";
    };
    const captureFromDocument = (document, fallbackId = "") => {
      const archiveUrl = document.querySelector('meta[property="og:url"]')?.content ?? "";
      const id = captureIdFromUrl(archiveUrl) || fallbackId;
      const originalUrl = originalUrlFromDocument(document);
      if (!id || !originalUrl)
        throw new Error("Archive.ph capture page is missing its capture identity");
      return {
        id,
        title: document.querySelector('meta[property="og:title"]')?.content ?? document.title ?? "",
        originalUrl,
        archiveUrl: archiveUrl || `${ORIGIN}/${id}`,
        capturedAt: document.querySelector('meta[property="article:published_time"]')?.content ?? "",
        screenshotUrl: document.querySelector('meta[property="og:image"]')?.content ?? ""
      };
    };
    const lookupUrl = (query) => `${ORIGIN}/${query.replaceAll("#", "%23")}`;
    const submitUrl = (url) => `${ORIGIN}/submit/?url=${encodeURIComponent(url)}`;
    action("searchCaptures", {
      async invoke({ query, limit = 20 }) {
        const document = await fetchDocument(lookupUrl(query), "searchCaptures");
        const items = [...document.querySelectorAll('[id^="row"]')].flatMap((row) => {
          const originalUrl = [...row.querySelectorAll(".TEXT-BLOCK a")].map((link) => link.innerText.trim()).find((value) => /^https?:\/\//.test(value)) ?? "";
          return [...row.querySelectorAll(".THUMBS-BLOCK a")].map((link) => {
            const id = captureIdFromUrl(link.href);
            const image = link.querySelector("img");
            if (!id || !image || !originalUrl)
              return null;
            return {
              id,
              title: image.title || image.alt.replace(/^screenshot of\s+/i, ""),
              originalUrl,
              archiveUrl: `${ORIGIN}/${id}`,
              capturedAt: link.querySelector("div")?.textContent?.trim() ?? "",
              thumbnailUrl: new URL(image.getAttribute("src") ?? "", ORIGIN).href
            };
          }).filter((item) => item !== null);
        }).slice(0, limit);
        return { items, nextCursor: null };
      }
    });
    action("getCapture", {
      async invoke({ id }) {
        if (!CAPTURE_ID.test(id))
          throw new Error(`getCapture: invalid capture id ${id}`);
        const document = await fetchDocument(`${ORIGIN}/${id}`, "getCapture");
        return captureFromDocument(document, id);
      }
    });
    action("createCapture", {
      async invoke({ url }) {
        const response = await fetch(submitUrl(url), { credentials: "include" });
        if (response.status === 429) {
          throw new Error("BOT_CONTROL_REQUIRED: Archive.ph needs human verification. Use request_bot_control with the same url, then continue from the completed capture.");
        }
        const document = await documentFrom(response, "createCapture");
        const capture = captureFromDocument(document);
        if (normalizedUrl(capture.originalUrl) !== normalizedUrl(url)) {
          throw new Error("createCapture: Archive.ph returned a capture for a different URL");
        }
        return capture;
      }
    });
    action("getBotControlUrl", {
      async invoke({ url }) {
        return { url: submitUrl(url) };
      }
    });
    action("getBotControlState", {
      async invoke({ url, pageUrl }) {
        const page = new URL(pageUrl);
        if (page.origin !== ORIGIN)
          return { ok: false };
        const id = captureIdFromUrl(page.href);
        if (!id)
          return { ok: false };
        const document = await fetchDocument(`${ORIGIN}/${id}`, "getBotControlState");
        return { ok: normalizedUrl(originalUrlFromDocument(document)) === normalizedUrl(url) };
      }
    });
  };
  var actions_default = install;

  // service-sdk/action-runtime.ts
  var patternMatches = (pattern, value) => {
    pattern.lastIndex = 0;
    const matched = pattern.test(value);
    pattern.lastIndex = 0;
    return matched;
  };
  function installFetchCapture(target) {
    const registrations = new Set;
    const recent = [];
    const matching = (url) => Array.from(registrations).filter((registration) => patternMatches(registration.pattern, url));
    const settle = (matched, result) => {
      for (const registration of matched) {
        if (!registrations.delete(registration))
          continue;
        clearTimeout(registration.timeout);
        if ("error" in result)
          registration.reject(result.error);
        else
          registration.resolve(result.value);
      }
    };
    const canReplay = (url) => {
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
      if (matched.length === 0 && !replayable)
        return;
      const value = read();
      if (replayable) {
        const entry = { url, value };
        recent.push(entry);
        while (recent.length > 32)
          recent.shift();
        value.catch(() => {
          const index = recent.indexOf(entry);
          if (index >= 0)
            recent.splice(index, 1);
        });
      }
      if (matched.length === 0)
        return;
      value.then((value2) => settle(matched, { value: value2 }), (error) => settle(matched, {
        error: new Error(`captured ${url} returned invalid JSON: ${String(error?.message ?? error)}`)
      }));
    };
    target.oxFetchCapture = (pattern, options) => {
      if (options?.replayLatest) {
        for (let index = recent.length - 1;index >= 0; index--) {
          if (patternMatches(pattern, recent[index].url))
            return recent[index].value;
        }
      }
      return new Promise((resolve, reject) => {
        const timeoutMs = options?.timeoutMs ?? 1e4;
        const registration = {};
        registration.pattern = pattern;
        registration.resolve = resolve;
        registration.reject = reject;
        registration.timeout = setTimeout(() => {
          if (!registrations.delete(registration))
            return;
          reject(new Error(`fetch capture timed out after ${timeoutMs}ms for ${pattern}`));
        }, timeoutMs);
        registrations.add(registration);
      });
    };
    const originalFetch = target.fetch.bind(target);
    target.fetch = (input, init) => originalFetch(input, init).then((response) => {
      const url = input instanceof Request ? input.url : String(input);
      capture(url, () => response.clone().json());
      return response;
    });
    const XHR = target.XMLHttpRequest;
    if (!XHR)
      return;
    const urls = new WeakMap;
    const originalOpen = XHR.prototype.open;
    const originalSend = XHR.prototype.send;
    XHR.prototype.open = function(...args) {
      urls.set(this, String(args[1] ?? ""));
      return originalOpen.apply(this, args);
    };
    XHR.prototype.send = function(...args) {
      this.addEventListener("loadend", () => {
        const url = urls.get(this) ?? this.responseURL;
        capture(url, async () => {
          if (this.responseType === "json")
            return this.response;
          return JSON.parse(this.responseText);
        });
      }, { once: true });
      return originalSend.apply(this, args);
    };
  }
  function installService(domain, installer) {
    installFetchCapture(window);
    const log = (msg) => {
      try {
        window.webkit?.messageHandlers?.oxConsole?.postMessage({
          level: "log",
          msg: `[service:${domain}] ${msg}`
        });
      } catch {}
    };
    const retryFetch = async (input, init, opts) => {
      const retries = opts?.retries ?? 3;
      const delay = opts?.delay ?? 400;
      const factor = opts?.factor ?? 2;
      const url = typeof input === "string" ? input : input.url;
      for (let attempt = 0;; attempt++) {
        try {
          const response = await window.fetch(input, init);
          const retryable = response.status === 408 || response.status === 429 || response.status >= 500 && response.status <= 599;
          if (response.ok || !retryable || attempt >= retries)
            return response;
          log(`retryFetch: status ${response.status}, attempt ${attempt + 1}/${retries}, url=${url}`);
        } catch (error) {
          const message = String(error?.message ?? "");
          const retryable = message.includes("Load failed") || message.includes("NetworkError") || message.includes("Failed to fetch");
          if (!retryable || attempt >= retries)
            throw error;
          log(`retryFetch: network ${JSON.stringify(message)}, attempt ${attempt + 1}/${retries}, url=${url}`);
        }
        await new Promise((resolve) => setTimeout(resolve, delay * Math.pow(factor, attempt)));
      }
    };
    const actions = new Map;
    const action = (name, definition) => {
      if (actions.has(name))
        throw new Error(`duplicate action: ${name}`);
      if (typeof definition?.invoke !== "function")
        throw new Error(`action ${name} has no invoke function`);
      actions.set(name, definition.invoke);
    };
    try {
      installer({ action, retryFetch, log });
    } catch (error) {
      log(`service installer threw: ${String(error?.stack ?? error?.message ?? error)}`);
      throw error;
    }
    const invoke = async (name, args) => {
      const handler = actions.get(name);
      if (!handler)
        throw new Error(`unknown action: ${name}`);
      try {
        return await handler(args ?? {});
      } catch (error) {
        log(`action ${JSON.stringify(name)} threw: ${String(error?.stack ?? error?.message ?? error)}`);
        throw new Error(`action ${JSON.stringify(name)} failed: ${String(error?.message ?? error)}`);
      }
    };
    const runtime = {
      callServiceAction: (name, args) => invoke(name, args)
    };
    window.ox = runtime;
  }

  installService("archive.ph", actions_default);
})();
