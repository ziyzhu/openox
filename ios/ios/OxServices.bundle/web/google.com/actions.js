(() => {
  // services/action-lib.ts
  function cleanText(value) {
    return String(value ?? "").replace(/\s+/g, " ").trim();
  }

  // services/builtin/web/google.com/actions.ts
  var ORIGIN = "https://www.google.com";
  var normalizedUrl = (value) => {
    try {
      const url = new URL(value, ORIGIN);
      const redirected = url.hostname.endsWith(".google.com") && url.pathname === "/url" ? url.searchParams.get("q") : null;
      const resolved = redirected ? new URL(redirected) : url;
      return resolved.protocol === "http:" || resolved.protocol === "https:" ? resolved.href : null;
    } catch {
      return null;
    }
  };
  var timestamp = (value) => {
    const seconds = Number(value);
    if (!Number.isFinite(seconds) || seconds <= 0)
      return null;
    const date = new Date(seconds * 1000);
    return Number.isFinite(date.getTime()) ? date.toISOString() : null;
  };
  var boundedLimit = (value) => {
    const parsed = typeof value === "number" ? value : Number(value);
    return Number.isInteger(parsed) ? Math.min(20, Math.max(1, parsed)) : 10;
  };
  var siteOf = (url) => {
    try {
      return new URL(url).hostname.toLowerCase();
    } catch {
      return "";
    }
  };
  function parseNewsResults(doc, limit) {
    const items = [];
    const seen = new Set;
    const anchors = [...doc.querySelectorAll("a[jsname='YKoRaf'][href]")];
    for (const heading of doc.querySelectorAll("h3")) {
      const anchor = heading.closest("a[href]");
      if (anchor && !anchors.includes(anchor))
        anchors.push(anchor);
    }
    for (const anchor of anchors) {
      const url = normalizedUrl(anchor.href);
      const title = cleanText((anchor.querySelector("[role='heading']") ?? anchor.querySelector("h3"))?.textContent);
      if (!url || !title || seen.has(url))
        continue;
      const site = siteOf(url);
      const sourceElement = anchor.querySelector(".MgUUmf.NUnG9d > span:last-child") ?? anchor.querySelector(".KogRLb") ?? anchor.querySelector(".BamJPe");
      const source = cleanText(sourceElement?.textContent).split("›")[0]?.trim() || site;
      const publishedAt = timestamp(anchor.querySelector("[data-ts]")?.getAttribute("data-ts") ?? null);
      const publishedText = cleanText((anchor.querySelector("[data-ts]") ?? anchor.querySelector(".UK5aid"))?.textContent);
      seen.add(url);
      items.push({ title, url, site, source, publishedAt, publishedText });
      if (items.length === limit)
        break;
    }
    return items;
  }
  function parseImageResults(doc, limit, thumbnailFor) {
    const items = [];
    const seen = new Set;
    const append = (sourceUrl, title, image) => {
      const thumbnailUrl = image ? thumbnailFor(image) : null;
      if (!sourceUrl || !title || !thumbnailUrl || seen.has(`${sourceUrl}
${thumbnailUrl}`))
        return;
      seen.add(`${sourceUrl}
${thumbnailUrl}`);
      items.push({ title, sourceUrl, site: siteOf(sourceUrl), thumbnailUrl });
    };
    for (const root of doc.querySelectorAll("[jsname='dTDiAc'][data-lpage]")) {
      const sourceUrl = normalizedUrl(root.getAttribute("data-lpage") ?? "");
      const image = root.querySelector("img[alt][id]");
      const title = cleanText(image?.alt);
      append(sourceUrl, title, image);
      if (items.length === limit)
        break;
    }
    if (items.length < limit) {
      for (const row of doc.querySelectorAll("tbody:has(img.DS1iW)")) {
        const image = row.querySelector("img.DS1iW");
        const anchor = image?.closest("a[href]");
        const sourceUrl = normalizedUrl(anchor?.href ?? "");
        const title = cleanText(row.querySelector(".qXLe6d.x3G5ab .fYyStc")?.textContent);
        append(sourceUrl, title, image);
        if (items.length === limit)
          break;
      }
    }
    return items;
  }
  function parseVideoResults(doc, limit, thumbnailFor) {
    const items = [];
    const seen = new Set;
    for (const heading of doc.querySelectorAll("h3")) {
      const anchor = heading.closest("a[href]");
      const url = normalizedUrl(anchor?.href ?? "");
      const title = cleanText(heading.textContent);
      if (!url || !title || seen.has(url))
        continue;
      const container = heading.closest("div[data-hveid]") ?? heading.closest(".Gx5Zad");
      if (!container)
        continue;
      const metadata = [...container.querySelectorAll(".gqF9jc > span")].map((element) => cleanText(element.textContent)).filter((value) => value && value !== "·");
      const site = siteOf(url);
      const basicSource = cleanText(container.querySelector(".BamJPe")?.textContent).split("›")[0]?.trim() || "";
      const detailText = cleanText(container.querySelector(".H66NU")?.textContent);
      const image = container.querySelector(".iHxmLe img[id], img[id]");
      seen.add(url);
      items.push({
        title,
        url,
        site,
        source: metadata[0] || basicSource || site,
        creator: metadata.length >= 3 ? metadata[1] ?? null : null,
        snippet: cleanText(container.querySelector(".ITZIwc")?.textContent) || detailText,
        duration: cleanText(container.querySelector(".kSFuOd span")?.textContent) || detailText.match(/Duration:\s*([0-9]+(?::[0-9]{2}){1,2})/)?.[1] || "",
        publishedText: metadata.at(-1) ?? cleanText(container.querySelector(".H66NU .UK5aid")?.textContent),
        thumbnailUrl: image ? thumbnailFor(image) : null
      });
      if (items.length === limit)
        break;
    }
    return items;
  }
  var install = ({ action, retryFetch, log }) => {
    const ensureSearchPage = (doc, responseUrl) => {
      const host = new URL(responseUrl, ORIGIN).hostname;
      if (host === "sorry.google.com" || doc.querySelector("form#captcha-form, form[action*='/sorry/']")) {
        throw new Error("Google requires a CAPTCHA");
      }
      if (host === "consent.google.com" || doc.querySelector("form[action*='consent.google.com']")) {
        throw new Error("Google requires consent");
      }
      if (host !== "google.com" && !host.endsWith(".google.com"))
        throw new Error(`Unexpected Google host ${host}`);
      return doc;
    };
    const isExplicitlyEmpty = (doc) => {
      const text = cleanText(doc.querySelector("#topstuff")?.textContent);
      return /did not match any documents|no results found/i.test(text) || doc.location.pathname === "/search" && !!doc.querySelector("#main") && !doc.querySelector(".Gx5Zad:not(#st-card), .MjjYud");
    };
    const thumbnailResolver = () => {
      const google = window.google;
      return (image) => {
        const candidate = google?.pim?.[image.id] ?? google?.ldi?.[image.id] ?? image.currentSrc ?? image.getAttribute("data-src") ?? image.getAttribute("src");
        return typeof candidate === "string" && /^https:\/\//.test(candidate) ? candidate : null;
      };
    };
    action("listSuggestions", {
      async invoke({ query } = {}) {
        if (!query)
          throw new Error("listSuggestions: query is required");
        const params = new URLSearchParams({ client: "firefox", q: query, hl: "en" });
        const response = await retryFetch(`/complete/s?${params}`, { credentials: "include" });
        if (!response.ok)
          throw new Error(`listSuggestions HTTP ${response.status}`);
        const text = await response.text();
        const json = JSON.parse(text.slice(text.indexOf("[")));
        const items = Array.isArray(json?.[1]) ? json[1].filter((value) => typeof value === "string") : [];
        return { items, nextCursor: null };
      }
    });
    action("searchNews", {
      async invoke({ query, limit } = {}) {
        if (!query)
          throw new Error("searchNews: query is required");
        const doc = ensureSearchPage(document, location.href);
        const items = parseNewsResults(doc, boundedLimit(limit));
        if (!items.length && !isExplicitlyEmpty(doc))
          throw new Error("Google news result markup was not recognized");
        const nextUrl = normalizedUrl(doc.querySelector("a#pnnext[href]")?.getAttribute("href") ?? "");
        const nextCursor = nextUrl ? new URL(nextUrl).searchParams.get("start") : null;
        log(`searchNews queryChars=${query.length} items=${items.length}`);
        return { items, nextCursor };
      }
    });
    action("searchImages", {
      async invoke({ query, limit } = {}) {
        if (!query)
          throw new Error("searchImages: query is required");
        const doc = ensureSearchPage(document, location.href);
        const items = parseImageResults(doc, boundedLimit(limit), thumbnailResolver());
        if (!items.length && !isExplicitlyEmpty(doc))
          throw new Error("Google image result markup was not recognized");
        log(`searchImages queryChars=${query.length} items=${items.length}`);
        return { items, nextCursor: null };
      }
    });
    action("searchVideos", {
      async invoke({ query, limit } = {}) {
        if (!query)
          throw new Error("searchVideos: query is required");
        const doc = ensureSearchPage(document, location.href);
        const items = parseVideoResults(doc, boundedLimit(limit), thumbnailResolver());
        if (!items.length && !isExplicitlyEmpty(doc))
          throw new Error("Google video result markup was not recognized");
        log(`searchVideos queryChars=${query.length} items=${items.length}`);
        return { items, nextCursor: null };
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

  installService("google.com", actions_default);
})();
