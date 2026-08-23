(() => {
  // services/action-lib.ts
  function cleanText(value) {
    return String(value ?? "").replace(/\s+/g, " ").trim();
  }
  function pageCursor(value, firstPage) {
    return Math.max(firstPage, Number.parseInt(value ?? String(firstPage), 10) || firstPage);
  }

  // services/builtin/web/dailymed.nlm.nih.gov/actions.ts
  var ORIGIN = "https://dailymed.nlm.nih.gov";
  var START_URL = `${ORIGIN}/dailymed/autocomplete.cfm?key=search&returntype=json&term=zzzzunlikelyqueryzzzz`;
  var FIELD_PREFIXES = {
    name: "NAME",
    ndc: "NDC",
    applicationNumber: "APPLICATION_NUMBER",
    setId: "SETID",
    documentId: "DOCUMENT_ID",
    drugClass: "CLASS",
    activeMoiety: "ACTIVEMOIETY",
    activeIngredient: "INGREDIENT",
    inactiveIngredient: "INACTIVE_INGREDIENT"
  };
  var textList = (element) => {
    if (!element)
      return [];
    const copy = element.cloneNode(true);
    copy.querySelectorAll("a").forEach((node) => node.remove());
    return cleanText(copy.textContent).split(",").map((value) => cleanText(value)).filter(Boolean);
  };
  var absoluteUrl = (value) => value ? new URL(value, ORIGIN).href : "";
  var readableText = (element) => {
    const copy = element.cloneNode(true);
    copy.querySelectorAll("br, p, li, tr, td, th, h1, h2, h3, h4").forEach((node) => node.before(" "));
    return cleanText(copy.textContent);
  };
  var install = ({ action, retryFetch, log }) => {
    const fetchDocument = async (url) => {
      const response = await retryFetch(url, { credentials: "omit" });
      if (!response.ok)
        throw new Error(`DailyMed HTTP ${response.status}`);
      const html = await response.text();
      return new DOMParser().parseFromString(html, "text/html");
    };
    action("searchDrugLabels", {
      async invoke({ query, field = "all", labelType = "all", cursor, limit = 20 }) {
        if (!query)
          throw new Error("searchDrugLabels: query is required");
        const page = pageCursor(cursor, 1);
        const pageSize = Math.min(200, Math.max(1, limit));
        const prefix = FIELD_PREFIXES[field];
        const searchQuery = prefix ? `${prefix}:(${query})` : query;
        const params = new URLSearchParams({
          labeltype: labelType,
          query: searchQuery,
          page: String(page),
          pagesize: String(pageSize)
        });
        if (prefix)
          params.set("adv", "1");
        const doc = await fetchDocument(`${ORIGIN}/dailymed/search.cfm?${params}`);
        const items = [...doc.querySelectorAll(".results article.row")].map((row) => {
          const link = row.querySelector("a.drug-info-link");
          const url = absoluteUrl(link?.getAttribute("href") ?? null);
          const id = url ? new URL(url).searchParams.get("setid") ?? "" : "";
          const packagerRow = [...row.querySelectorAll(".drug-information li")].find((node) => /^Packager:/i.test(cleanText(node.textContent)));
          const packager = cleanText(packagerRow?.textContent).replace(/^Packager:\s*/i, "");
          return {
            id,
            title: cleanText(link?.textContent),
            ndcCodes: textList(row.querySelector(".ndc-codes")),
            ...packager ? { packager } : {},
            url
          };
        }).filter((item) => item.id && item.title && item.url);
        const countText = cleanText(doc.querySelector(".header .count, span.count")?.textContent);
        const totalCount = Number.parseInt(countText.replace(/\D/g, ""), 10) || 0;
        const nextHref = doc.querySelector(".pagination a.next-link")?.getAttribute("href");
        const nextCursor = nextHref ? new URL(nextHref, ORIGIN).searchParams.get("page") : null;
        log(`searchDrugLabels ${field} "${query}" page ${page}: ${items.length}/${totalCount}`);
        return { items, totalCount, nextCursor };
      }
    });
    action("getDrugLabel", {
      async invoke({ id }) {
        if (!id)
          throw new Error("getDrugLabel: id is required");
        const params = new URLSearchParams({ setid: id });
        const url = `${ORIGIN}/dailymed/drugInfo.cfm?${params}`;
        const doc = await fetchDocument(url);
        const title = cleanText(doc.querySelector("#drug-label")?.textContent);
        if (!title)
          throw new Error(`getDrugLabel: no label found for id ${id}`);
        const metadataRows = [...doc.querySelectorAll(".content-wide > article > ul.drug-information li")];
        const metadata = (label) => {
          const row = metadataRows.find((node) => cleanText(node.querySelector("strong")?.textContent).toLowerCase().startsWith(label.toLowerCase()));
          return cleanText(row?.textContent).replace(new RegExp(`^${label}\\s*:?\\s*`, "i"), "");
        };
        const sections = [...doc.querySelectorAll(".drug-label-sections .Section[data-sectioncode]")].map((section) => ({
          title: cleanText(section.previousElementSibling?.textContent),
          code: section.getAttribute("data-sectioncode") ?? "",
          text: readableText(section)
        })).filter((section) => section.title && section.text);
        const updated = cleanText(doc.querySelector("#drug-information p.date")?.textContent).replace(/^Updated\s*/i, "");
        const category = cleanText(doc.querySelector("#category")?.textContent);
        const deaSchedule = cleanText(doc.querySelector("#dea-schedule")?.textContent);
        const marketingStatus = cleanText(doc.querySelector("#marketing-status")?.textContent);
        const packager = metadata("Packager");
        const pdfUrl = absoluteUrl(doc.querySelector("a.pdf")?.getAttribute("href") ?? null);
        const xmlZipUrl = absoluteUrl(doc.querySelector("a.xml")?.getAttribute("href") ?? null);
        const officialLabelUrl = absoluteUrl(doc.querySelector("a[href*='fdaDrugXsl.cfm']")?.getAttribute("href") ?? null);
        const result = {
          id,
          title,
          ndcCodes: textList(doc.querySelector("#item-code-s")),
          sections,
          url,
          ...packager ? { packager } : {},
          ...category ? { category } : {},
          ...deaSchedule ? { deaSchedule } : {},
          ...marketingStatus ? { marketingStatus } : {},
          ...updated ? { updated } : {},
          ...pdfUrl ? { pdfUrl } : {},
          ...xmlZipUrl ? { xmlZipUrl } : {},
          ...officialLabelUrl ? { officialLabelUrl } : {}
        };
        log(`getDrugLabel ${id}: ${sections.length} sections`);
        return result;
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

  installService("dailymed.nlm.nih.gov", actions_default);
})();
