(() => {
  // services/action-lib.ts
  function pageCursor(value, firstPage) {
    return Math.max(firstPage, Number.parseInt(value ?? String(firstPage), 10) || firstPage);
  }

  // services/builtin/web/www.uscis.gov/actions.ts
  var ORIGIN = "https://www.uscis.gov";
  var install = ({ action, retryFetch, log }) => {
    const absUrl = (p) => {
      if (!p)
        return "";
      if (/^https?:\/\//.test(p))
        return p;
      return ORIGIN + (p.startsWith("/") ? p : `/${p}`);
    };
    action("getPage", {
      async invoke({ path } = {}) {
        if (!path)
          throw new Error("path is required");
        const url = absUrl(path);
        if (!url.startsWith(ORIGIN))
          throw new Error("path must be on www.uscis.gov");
        const html = await (await retryFetch(url, { credentials: "include" })).text();
        const doc = new DOMParser().parseFromString(html, "text/html");
        const title = (doc.querySelector("h1")?.textContent || doc.title || "").trim();
        const main = doc.querySelector("main#main") || doc.querySelector(".main-content-wrapper") || doc.querySelector("main") || doc.body;
        main.querySelectorAll("script,style,noscript,nav,header,footer,form,iframe,.usa-banner,.skip-links").forEach((e) => e.remove());
        const text = (main.textContent || "").replace(/[ \t]+/g, " ").replace(/\n[ \t]+/g, `
`).replace(/\n{3,}/g, `

`).trim();
        const seen = new Set;
        const links = [...main.querySelectorAll("a[href]")].map((a) => ({
          text: (a.textContent || "").trim(),
          url: absUrl(a.getAttribute("href") || "")
        })).filter((l) => l.text && /^https?:\/\//.test(l.url) && !seen.has(l.url) && seen.add(l.url)).slice(0, 80);
        return { url, title, text: text.slice(0, 20000), links };
      }
    });
    const renderSearch = async (query) => {
      const iframe = document.createElement("iframe");
      iframe.style.cssText = "position:absolute;left:-99999px;top:0;width:1024px;height:3000px;visibility:hidden;";
      const loaded = new Promise((res) => {
        iframe.onload = () => res();
      });
      document.body.appendChild(iframe);
      iframe.src = `${ORIGIN}/search?query=${encodeURIComponent(query)}`;
      await loaded;
      let doc = iframe.contentDocument;
      const ready = () => doc && doc.querySelector(".gsc-webResult.gsc-result, .gs-no-results-result, .gsc-results");
      for (let i = 0;i < 60 && !ready(); i++) {
        await new Promise((r) => setTimeout(r, 200));
        doc = iframe.contentDocument;
      }
      return { iframe, doc };
    };
    action("searchSite", {
      async invoke({ query } = {}) {
        let iframe;
        try {
          if (!query)
            throw new Error("query is required");
          const r = await renderSearch(query);
          iframe = r.iframe;
          const doc = r.doc;
          if (!doc)
            throw new Error("search did not render");
          const items = [...doc.querySelectorAll(".gsc-webResult.gsc-result")].map((el) => {
            const a = el.querySelector("a.gs-title");
            const url = a?.getAttribute("data-ctorig") || a?.getAttribute("href") || "";
            const title = (a?.textContent || "").replace(/\s+/g, " ").trim();
            const snippet = (el.querySelector(".gs-snippet")?.textContent || "").replace(/\s+/g, " ").trim();
            return { title, url, snippet };
          }).filter((x) => x.title && /^https?:\/\//.test(x.url));
          log(`uscis search "${query}" -> ${items.length} results`);
          return { items, nextCursor: null };
        } finally {
          iframe?.remove();
        }
      }
    });
    const clean = (s) => (s || "").replace(/\s+/g, " ").trim();
    action("listNews", {
      async invoke({ cursor } = {}) {
        const page = pageCursor(cursor, 0);
        const url = `${ORIGIN}/newsroom/all-news?page=${page}`;
        const html = await (await retryFetch(url, { credentials: "include" })).text();
        const doc = new DOMParser().parseFromString(html, "text/html");
        const items = [...doc.querySelectorAll(".views-row")].map((row) => {
          const a = row.querySelector(".views-field-title a");
          return {
            title: clean(a?.textContent),
            url: absUrl(a?.getAttribute("href") || ""),
            date: clean(row.querySelector(".views-field-field-display-date")?.textContent),
            summary: clean(row.querySelector(".views-field-body")?.textContent)
          };
        }).filter((x) => x.title && x.url);
        const hasNext = !!doc.querySelector(".pager__item--next a, a[rel='next']");
        return { items, nextCursor: hasNext ? String(page + 1) : null };
      }
    });
    action("getForm", {
      async invoke({ form } = {}) {
        if (!form)
          throw new Error("form is required");
        const slug = form.toLowerCase().replace(/[^a-z0-9-]/g, "");
        const url = `${ORIGIN}/${slug}`;
        const html = await (await retryFetch(url, { credentials: "include" })).text();
        const doc = new DOMParser().parseFromString(html, "text/html");
        const title = clean(doc.querySelector("h1")?.textContent || doc.title);
        const scope = doc.querySelector(".field--name-field-attached-files") || doc.querySelector("main#main") || doc.body;
        const seen = new Set;
        const files = [...scope.querySelectorAll("a[href$='.pdf']")].map((a) => {
          const info = a.closest(".media--type-document, .file")?.querySelector(".file-ext-info, .extra-info") || null;
          return {
            label: clean(a.textContent),
            url: absUrl(a.getAttribute("href") || ""),
            info: clean(info?.textContent)
          };
        }).filter((f) => f.url && !seen.has(f.url) && seen.add(f.url));
        if (files.length === 0)
          throw new Error(`no downloadable PDF found for ${form} at ${url}`);
        return { form, title, url, files };
      }
    });
  };
  var actions_default = install;

  // services/action-runtime.ts
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

  installService("www.uscis.gov", actions_default);
})();
