(() => {
  // service-sdk/action-lib.ts
  function pageCursor(value, firstPage) {
    return Math.max(firstPage, Number.parseInt(value ?? String(firstPage), 10) || firstPage);
  }

  // services/builtin/web/www.qbitai.com/actions.ts
  var install = ({ action, retryFetch }) => {
    const API = "https://www.qbitai.com/wp-json/wp/v2";
    const htmlToText = (html) => {
      const doc = new DOMParser().parseFromString(html ?? "", "text/html");
      return (doc.body?.textContent ?? "").replace(/\s+/g, " ").trim();
    };
    const getJson = async (path) => {
      const res = await retryFetch(`${API}${path}`, { credentials: "include" });
      if (!res.ok)
        throw new Error(`HTTP ${res.status} for ${path}`);
      return { body: await res.json(), totalPages: parseInt(res.headers.get("X-WP-TotalPages") ?? "0", 10) || 0 };
    };
    const summaryOf = (p) => {
      const media = p?._embedded?.["wp:featuredmedia"]?.[0];
      return {
        id: String(p.id),
        title: htmlToText(p?.title?.rendered ?? ""),
        excerpt: htmlToText(p?.excerpt?.rendered ?? ""),
        url: p?.link ?? "",
        date: p?.date ?? "",
        author: p?._embedded?.author?.[0]?.name ?? "",
        image: media?.source_url ?? null
      };
    };
    const articleOf = (p) => {
      const terms = (p?._embedded?.["wp:term"] ?? []).flat();
      return {
        ...summaryOf(p),
        content: htmlToText(p?.content?.rendered ?? ""),
        tags: terms.map((t) => t?.name).filter(Boolean)
      };
    };
    const listPage = async (path, limit, cursor) => {
      const page = pageCursor(cursor, 1);
      const lim = Math.min(Math.max(limit, 1), 50);
      const { body, totalPages } = await getJson(`${path}per_page=${lim}&page=${page}&_embed=1`);
      const items = (Array.isArray(body) ? body : []).map(summaryOf);
      const nextCursor = page < totalPages && items.length === lim ? String(page + 1) : null;
      return { items, nextCursor };
    };
    action("listPosts", {
      async invoke({ limit = 20, cursor } = {}) {
        return await listPage("/posts?", limit, cursor);
      }
    });
    action("searchPosts", {
      async invoke({ query, limit = 20, cursor }) {
        if (!query)
          throw new Error("searchPosts: query is required");
        return await listPage(`/posts?search=${encodeURIComponent(query)}&`, limit, cursor);
      }
    });
    action("getPost", {
      async invoke({ id }) {
        const { body } = await getJson(`/posts/${encodeURIComponent(id)}?_embed=1`);
        if (!body?.id)
          throw new Error(`getPost: no article for id ${id}`);
        return articleOf(body);
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

  installService("www.qbitai.com", actions_default);
})();
