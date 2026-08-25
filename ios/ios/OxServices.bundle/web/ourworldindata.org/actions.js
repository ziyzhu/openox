(() => {
  // service-sdk/action-lib.ts
  function pageCursor(value, firstPage) {
    return Math.max(firstPage, Number.parseInt(value ?? String(firstPage), 10) || firstPage);
  }

  // services/builtin/web/ourworldindata.org/actions.ts
  var install = ({ action, retryFetch, log }) => {
    const ORIGIN = "https://ourworldindata.org";
    const ALGOLIA_APP_ID = "ASCB5XMYF2";
    const ALGOLIA_API_KEY = "bafe9c4659e5657bf750a38fbee5c269";
    const ALGOLIA_URL = `https://${ALGOLIA_APP_ID.toLowerCase()}-dsn.algolia.net/1/indexes/*/queries` + `?x-algolia-api-key=${ALGOLIA_API_KEY}&x-algolia-application-id=${ALGOLIA_APP_ID}`;
    const algolia = async (req) => {
      const res = await retryFetch(ALGOLIA_URL, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ requests: [req] })
      });
      if (!res.ok)
        throw new Error(`algolia ${res.status}`);
      const json = await res.json();
      const result = json?.results?.[0];
      if (!result)
        throw new Error("algolia: empty result");
      return result;
    };
    const pageUrl = (type, slug) => {
      if (type === "data-insight")
        return `${ORIGIN}/data-insights/${slug}`;
      if (type === "explorerView" || type === "explorer")
        return `${ORIGIN}/explorers/${slug}`;
      if (type === "chart")
        return `${ORIGIN}/grapher/${slug}`;
      return `${ORIGIN}/${slug}`;
    };
    const paginate = (result) => result.page + 1 < result.nbPages ? String(result.page + 1) : null;
    action("search", {
      async invoke({ query, cursor, limit = 20 } = {}) {
        const result = await algolia({
          indexName: "pages",
          query: query ?? "",
          attributesToRetrieve: ["title", "slug", "type", "date", "excerpt", "authors"],
          hitsPerPage: limit,
          page: pageCursor(cursor, 0)
        });
        const items = result.hits.map((h) => ({
          type: h.type ?? "",
          title: h.title ?? "",
          slug: h.slug ?? "",
          url: pageUrl(h.type ?? "", h.slug ?? ""),
          date: h.date ?? null,
          excerpt: h.excerpt ?? null,
          authors: Array.isArray(h.authors) ? h.authors : []
        }));
        return { items, nextCursor: paginate(result) };
      }
    });
    action("searchCharts", {
      async invoke({ query, cursor, limit = 20 } = {}) {
        const result = await algolia({
          indexName: "explorer-views-and-charts",
          query: query ?? "",
          attributesToRetrieve: [
            "title",
            "containerTitle",
            "subtitle",
            "slug",
            "variantName",
            "type",
            "availableEntities"
          ],
          hitsPerPage: limit,
          page: pageCursor(cursor, 0)
        });
        const items = result.hits.map((h) => ({
          type: h.type ?? "",
          title: h.title ?? "",
          subtitle: h.subtitle ?? null,
          variantName: h.variantName ?? null,
          slug: h.slug ?? "",
          url: pageUrl(h.type ?? "", h.slug ?? ""),
          availableEntities: Array.isArray(h.availableEntities) ? h.availableEntities : []
        }));
        return { items, nextCursor: paginate(result) };
      }
    });
    action("listLatest", {
      async invoke({ cursor, limit = 20 } = {}) {
        const result = await algolia({
          indexName: "pages-chronological",
          query: "",
          filters: "type:article OR type:data-insight OR type:announcement",
          hitsPerPage: limit,
          page: pageCursor(cursor, 0)
        });
        const items = result.hits.map((h) => ({
          type: h.type ?? "",
          title: h.title ?? "",
          slug: h.slug ?? "",
          url: pageUrl(h.type ?? "", h.slug ?? ""),
          date: h.date ?? null,
          authors: Array.isArray(h.authors) ? h.authors : []
        }));
        return { items, nextCursor: paginate(result) };
      }
    });
    action("getChartData", {
      async invoke({ slug, entities } = {}) {
        try {
          if (!slug)
            throw new Error("getChartData: slug is required");
          const params = new URLSearchParams({ version: "1", variant: "medium" });
          if (entities)
            params.set("entities", `~${entities}`);
          const url = `${ORIGIN}/grapher/${encodeURIComponent(slug)}.search-result.json?${params}`;
          const res = await retryFetch(url, { credentials: "include" });
          if (!res.ok)
            throw new Error(`getChartData: ${slug} HTTP ${res.status}`);
          const data = await res.json();
          const rows = Array.isArray(data?.dataTable?.rows) ? data.dataTable.rows.map((r) => ({
            entity: r.seriesName ?? r.label ?? "",
            value: r.value ?? null,
            time: r.time ?? null
          })) : [];
          const vd = data?.valueDisplay ?? {};
          return {
            slug,
            title: data?.title ?? "",
            unit: data?.unit ?? null,
            source: data?.source ?? null,
            url: `${ORIGIN}/grapher/${slug}`,
            latest: vd.endValue ? { entity: vd.entityName ?? "", value: vd.endValue, time: vd.time ?? null } : null,
            rows
          };
        } catch (e) {
          log(`getChartData failed: ${e?.message ?? e}`);
          throw e;
        }
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

  installService("ourworldindata.org", actions_default);
})();
