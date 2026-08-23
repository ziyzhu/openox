(() => {
  // services/action-lib.ts
  function pageCursor(value, firstPage) {
    return Math.max(firstPage, Number.parseInt(value ?? String(firstPage), 10) || firstPage);
  }

  // services/builtin/web/huggingface.co/actions.ts
  var install = ({ action, retryFetch, log }) => {
    const ORIGIN = "https://huggingface.co";
    const fetchJson = async (path) => {
      const response = await retryFetch(`${ORIGIN}${path}`, {
        credentials: "include",
        headers: { Accept: "application/json" }
      });
      if (!response.ok)
        throw new Error(`GET ${path} -> ${response.status}`);
      return response.json();
    };
    const nextPage = (page, pageSize, total) => page * pageSize < total ? String(page + 1) : null;
    action("listModels", {
      async invoke({ library, cursor }) {
        const page = pageCursor(cursor, 1);
        const query = new URLSearchParams({
          p: String(page),
          sort: "trending",
          withCount: "true"
        });
        if (library)
          query.set("library", library);
        const data = await fetchJson(`/models-json?${query}`);
        const models = data.models ?? [];
        log(`listModels: page ${page}, ${models.length} models`);
        return {
          items: models.map((model) => ({
            id: model.id,
            author: model.author ?? null,
            task: model.pipeline_tag ?? null,
            downloads: model.downloads ?? 0,
            likes: model.likes ?? 0,
            parameters: model.numParameters ?? null,
            gated: !!model.gated,
            updatedAt: model.lastModified ?? null,
            url: `${ORIGIN}/${model.id}`
          })),
          nextCursor: nextPage(data.pageIndex ?? page, data.numItemsPerPage ?? models.length, data.numTotalItems ?? models.length)
        };
      }
    });
    action("listDatasets", {
      async invoke({ cursor }) {
        const page = pageCursor(cursor, 1);
        const query = new URLSearchParams({
          p: String(page),
          sort: "trending",
          withCount: "true"
        });
        const data = await fetchJson(`/datasets-json?${query}`);
        const datasets = data.datasets ?? [];
        log(`listDatasets: page ${page}, ${datasets.length} datasets`);
        return {
          items: datasets.map((dataset) => ({
            id: dataset.id,
            author: dataset.author ?? null,
            downloads: dataset.downloads ?? 0,
            likes: dataset.likes ?? 0,
            gated: !!dataset.gated,
            benchmark: !!dataset.isBenchmark,
            updatedAt: dataset.lastModified ?? null,
            url: `${ORIGIN}/datasets/${dataset.id}`
          })),
          nextCursor: nextPage(data.pageIndex ?? page, data.numItemsPerPage ?? datasets.length, data.numTotalItems ?? datasets.length)
        };
      }
    });
    action("listSpaces", {
      async invoke({ category }) {
        const query = new URLSearchParams({
          category,
          includeNonRunning: "true"
        });
        const spaces = await fetchJson(`/api/spaces/semantic-search?${query}`);
        log(`listSpaces: ${spaces.length} spaces in ${category}`);
        return {
          items: spaces.map((space) => ({
            id: space.id,
            title: space.title || space.id,
            author: space.author ?? null,
            description: space.ai_short_description ?? space.shortDescription ?? null,
            category: space.ai_category ?? null,
            sdk: space.sdk ?? null,
            likes: space.likes ?? 0,
            running: space.runtime?.stage === "RUNNING",
            updatedAt: space.lastModified ?? null,
            url: `${ORIGIN}/spaces/${space.id}`
          })),
          nextCursor: null
        };
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

  installService("huggingface.co", actions_default);
})();
