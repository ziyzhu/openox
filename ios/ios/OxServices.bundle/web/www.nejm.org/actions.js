(() => {
  // services/action-lib.ts
  function cleanText(value) {
    return String(value ?? "").replace(/\s+/g, " ").trim();
  }
  function pageCursor(value, firstPage) {
    return Math.max(firstPage, Number.parseInt(value ?? String(firstPage), 10) || firstPage);
  }

  // services/builtin/web/www.nejm.org/actions.ts
  var ORIGIN = "https://www.nejm.org";
  var START_URL = `${ORIGIN}/action/autoCompleteSearchService?partialQuery=zzzzunlikelyqueryzzzz`;
  var inputValue = (element, selector) => element.querySelector(selector)?.value?.trim() ?? "";
  var absoluteUrl = (value) => value ? new URL(value, ORIGIN).href : "";
  var readableText = (element) => {
    if (!element)
      return "";
    const copy = element.cloneNode(true);
    copy.querySelectorAll("script, style, button, svg, .external-links").forEach((node) => node.remove());
    copy.querySelectorAll("br, p, li, tr, h1, h2, h3, h4, [role='paragraph']").forEach((node) => node.before(" "));
    return cleanText(copy.textContent);
  };
  var articleItems = (doc) => [...doc.querySelectorAll(".os-search-results_list-item .issue-item")].map((element) => {
    const id = inputValue(element, ".inputDoi");
    const titleLink = element.querySelector(".issue-item_title-link");
    const title = inputValue(element, ".inputArticleTitle") || cleanText(titleLink?.textContent);
    const url = absoluteUrl(titleLink?.getAttribute("href") ?? null);
    const authors = inputValue(element, ".inputAuthor") || cleanText(element.querySelector(".issue-item_authors")?.textContent);
    const citation = inputValue(element, ".inputCitation") || cleanText(element.querySelector(".issue-item_authors-after")?.textContent);
    const publishedAt = inputValue(element, ".inputEPubDate") || cleanText(element.querySelector(".issue-item_date")?.textContent);
    const articleType = inputValue(element, ".inputContentType") || cleanText(element.querySelector(".issue-item_type")?.textContent);
    const snippet = readableText(element.querySelector(".issue-item_abstractText"));
    const pdfUrl = absoluteUrl(element.querySelector("a.issue-item_pdf")?.getAttribute("href") ?? null);
    return {
      id,
      title,
      url,
      ...authors ? { authors } : {},
      ...citation ? { citation } : {},
      ...publishedAt ? { publishedAt } : {},
      ...articleType ? { articleType } : {},
      ...snippet ? { snippet } : {},
      ...pdfUrl ? { pdfUrl } : {}
    };
  }).filter((item) => item.id && item.title && item.url);
  var totalCount = (doc) => {
    const value = doc.querySelector("input[name='total']")?.value ?? "";
    return Number.parseInt(value.replace(/\D/g, ""), 10) || 0;
  };
  var nextCursor = (doc) => doc.querySelector(".ng-pagination_next[aria-disabled='false']")?.dataset.startpage ?? null;
  var install = ({ action, retryFetch, log }) => {
    const fetchDocument = async (url) => {
      const response = await retryFetch(url, { credentials: "include" });
      if (!response.ok)
        throw new Error(`NEJM HTTP ${response.status}`);
      const html = await response.text();
      return new DOMParser().parseFromString(html, "text/html");
    };
    const fetchResultsPage = async ({
      firstUrl,
      page,
      searchType,
      subPageType,
      pbContext,
      query
    }) => {
      const firstPage = await fetchDocument(firstUrl);
      if (page === 1)
        return { doc: firstPage, firstPage };
      const widgetId = firstPage.querySelector("input[name='widgetID']")?.value;
      if (!widgetId)
        throw new Error("NEJM results widget was not found");
      const params = new URLSearchParams({
        startPage: String(page),
        isFiltered: "true",
        pbContext,
        widgetId,
        searchType,
        subPageType
      });
      if (query)
        params.set("q", query);
      const doc = await fetchDocument(`${ORIGIN}/pb/widgets/mmsSearchResults?${params}`);
      return { doc, firstPage };
    };
    action("searchArticles", {
      async invoke({ query, cursor }) {
        if (!query)
          throw new Error("searchArticles: query is required");
        const page = pageCursor(cursor, 1);
        const params = new URLSearchParams({ q: query });
        const { doc } = await fetchResultsPage({
          firstUrl: `${ORIGIN}/search?${params}`,
          page,
          searchType: "quickSearch",
          subPageType: "",
          pbContext: ";page:string:Search Result;wgroup:string:MMS NextGen Website Group;pageGroup:string:Search Flow;website:website:mms-site",
          query
        });
        const items = articleItems(doc);
        const total = totalCount(doc);
        const next = nextCursor(doc);
        log(`searchArticles "${query}" page ${page}: ${items.length}/${total}`);
        return { items, totalCount: total, nextCursor: next };
      }
    });
    action("listSpecialtyArticles", {
      async invoke({ specialty, cursor }) {
        if (!specialty)
          throw new Error("listSpecialtyArticles: specialty is required");
        const page = pageCursor(cursor, 1);
        const firstUrl = `${ORIGIN}/browse/specialty/${encodeURIComponent(specialty)}`;
        const { doc, firstPage } = await fetchResultsPage({
          firstUrl,
          page,
          searchType: "browseSpecialty",
          subPageType: specialty,
          pbContext: `;subPage:string:Topic Landing Page;taxonomy:taxonomy:specialty;topic:topic:specialty>${specialty};page:string:Search Result;wgroup:string:MMS NextGen Website Group;pageGroup:string:Search Flow;website:website:mms-site`
        });
        const name = cleanText(firstPage.querySelector(".ng-page_title-heading")?.textContent) || specialty;
        const items = articleItems(doc);
        const total = totalCount(doc);
        const next = nextCursor(doc);
        log(`listSpecialtyArticles ${specialty} page ${page}: ${items.length}/${total}`);
        return { name, items, totalCount: total, nextCursor: next };
      }
    });
    action("getArticle", {
      async invoke({ id }) {
        if (!id)
          throw new Error("getArticle: id is required");
        const doiPath = id.split("/").map(encodeURIComponent).join("/");
        const url = `${ORIGIN}/doi/full/${doiPath}`;
        const doc = await fetchDocument(url);
        const metadata = (name) => cleanText(doc.querySelector(`meta[name='${name}']`)?.content);
        const title = cleanText(doc.querySelector("h1[property='name']")?.textContent) || metadata("dc.Title");
        if (!title)
          throw new Error(`getArticle: no article found for ${id}`);
        const authors = [...doc.querySelectorAll("meta[name='dc.Creator']")].map((element) => cleanText(element.content)).filter(Boolean);
        const description = metadata("dc.Description");
        const publishedAt = metadata("dc.Date");
        const articleType = metadata("dc.Type");
        const abstract = readableText(doc.querySelector("#summary-abstract"));
        const sections = [...doc.querySelectorAll("#bodymatter > .core-container > section")].map((section) => ({
          title: cleanText(section.querySelector(":scope > h2")?.textContent),
          text: readableText(section)
        })).filter((section) => section.title && section.text);
        const topics = [...doc.querySelectorAll("[property='keywords'] a")].map((element) => cleanText(element.textContent)).filter(Boolean);
        const notices = [...doc.querySelectorAll(".core-relations .relation--head")].map((element) => readableText(element)).filter(Boolean);
        const pdfUrl = absoluteUrl(doc.querySelector("a.btn--pdf")?.getAttribute("href") ?? null);
        log(`getArticle ${id}: ${authors.length} authors, ${sections.length} sections`);
        return {
          id,
          title,
          authors,
          topics,
          notices,
          sections,
          url,
          ...description ? { description } : {},
          ...publishedAt ? { publishedAt } : {},
          ...articleType ? { articleType } : {},
          ...abstract ? { abstract } : {},
          ...pdfUrl ? { pdfUrl } : {}
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

  installService("www.nejm.org", actions_default);
})();
