(() => {
  // services/builtin/web/en.wikipedia.org/actions.ts
  var install = ({ action, retryFetch }) => {
    const ORIGIN = "https://en.wikipedia.org";
    const fetchJson = async (path) => {
      const res = await retryFetch(`${ORIGIN}${path}`, { credentials: "include" });
      if (!res.ok)
        throw new Error(`GET ${path} -> ${res.status}`);
      return res.json();
    };
    const stripHtml = (html) => {
      const doc = new DOMParser().parseFromString(html ?? "", "text/html");
      return (doc.documentElement.textContent ?? "").replace(/\s+/g, " ").trim();
    };
    const absUrl = (u) => u ? u.startsWith("//") ? `https:${u}` : u : null;
    const articleUrl = (key) => `${ORIGIN}/wiki/${encodeURIComponent(key.replace(/ /g, "_"))}`;
    const searchItem = (p) => ({
      key: p.key,
      title: p.title,
      description: p.description ?? null,
      excerpt: stripHtml(p.excerpt ?? ""),
      url: articleUrl(p.key),
      thumbnailUrl: absUrl(p.thumbnail?.url)
    });
    const searchPage = async (query, limit) => {
      const data = await fetchJson(`/w/rest.php/v1/search/page?q=${encodeURIComponent(query)}&limit=${limit}`);
      return { items: (data.pages ?? []).map(searchItem), nextCursor: null };
    };
    action("searchArticles", {
      async invoke({ query, limit = 10 }) {
        return await searchPage(query, limit);
      }
    });
    action("listRelatedArticles", {
      async invoke({ title, limit = 10 }) {
        return await searchPage(`morelike:${title}`, limit);
      }
    });
    action("getArticleSummary", {
      async invoke({ title }) {
        const data = await fetchJson(`/api/rest_v1/page/summary/${encodeURIComponent(title.replace(/ /g, "_"))}`);
        return {
          key: data.titles?.canonical ?? title,
          title: data.title,
          type: data.type ?? "standard",
          description: data.description ?? null,
          extract: data.extract ?? "",
          url: data.content_urls?.desktop?.page ?? articleUrl(title),
          thumbnailUrl: absUrl(data.thumbnail?.source),
          updatedAt: data.timestamp ?? null
        };
      }
    });
    const ARTICLE_NOISE = "style,script,table,figure,img,sup.reference,.mw-editsection,.reflist,.refbegin,.mw-references-wrap,ol.references,.navbox,.sidebar,.shortdescription,.hatnote";
    action("getArticle", {
      async invoke({ title }) {
        const res = await retryFetch(articleUrl(title), { credentials: "include" });
        if (!res.ok)
          throw new Error(`getArticle: "${title}" -> ${res.status}`);
        const doc = new DOMParser().parseFromString(await res.text(), "text/html");
        const root = doc.querySelector("#mw-content-text .mw-parser-output");
        if (!root)
          throw new Error(`getArticle: no article content for "${title}"`);
        for (const el of root.querySelectorAll(ARTICLE_NOISE))
          el.remove();
        const text = (el) => (el?.textContent ?? "").replace(/\s+/g, " ").trim();
        const sections = [{ heading: "", parts: [] }];
        for (const child of root.children) {
          const headingEl = child.classList.contains("mw-heading") ? child.querySelector("h2,h3,h4") : /^H[234]$/.test(child.tagName) ? child : null;
          if (headingEl) {
            sections.push({ heading: text(headingEl), parts: [] });
            continue;
          }
          const t = text(child);
          if (t)
            sections[sections.length - 1].parts.push(t);
        }
        return {
          title: text(doc.querySelector("#firstHeading")) || title,
          url: doc.querySelector('link[rel="canonical"]')?.getAttribute("href") ?? articleUrl(title),
          sections: sections.map((s) => ({ heading: s.heading, text: s.parts.join(`

`) })).filter((s) => s.text)
        };
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

  installService("en.wikipedia.org", actions_default);
})();
