(() => {
  // services/action-lib.ts
  function cleanText(value) {
    return String(value ?? "").replace(/\s+/g, " ").trim();
  }
  function pageCursor(value, firstPage) {
    return Math.max(firstPage, Number.parseInt(value ?? String(firstPage), 10) || firstPage);
  }

  // services/builtin/web/www.nature.com/actions.ts
  var ORIGIN = "https://www.nature.com";
  var START_URL = `${ORIGIN}/search?q=zzzzunlikelyqueryzzzz`;
  var absoluteUrl = (value) => value ? new URL(value, ORIGIN).href : "";
  var articleId = (url) => {
    const match = new URL(url, ORIGIN).pathname.match(/^\/articles\/([^/]+)/);
    return match ? decodeURIComponent(match[1] ?? "") : "";
  };
  var articleCard = (element, fallbackJournal = null) => {
    const link = element.querySelector('.c-card__title a[href*="/articles/"]');
    const url = absoluteUrl(link?.getAttribute("href") ?? null);
    const summary = cleanText(element.querySelector('[data-test="article-description"]')?.textContent);
    const articleType = cleanText(element.querySelector('[data-test="article.type"]')?.textContent);
    const publishedAt = element.querySelector('time[itemprop="datePublished"]')?.dateTime ?? "";
    const journal = cleanText(element.querySelector('[data-test="journal-title-and-link"]')?.textContent) || fallbackJournal;
    return {
      id: articleId(url),
      title: cleanText(link?.textContent),
      authors: [...element.querySelectorAll('[itemprop="creator"] [itemprop="name"]')].map((author) => cleanText(author.textContent)).filter(Boolean),
      summary: summary || null,
      articleType: articleType || null,
      publishedAt: publishedAt || null,
      journal,
      openAccess: !!element.querySelector('[data-test="open-access"]'),
      url
    };
  };
  var install = ({ action, retryFetch, log }) => {
    const fetchDocument = async (url) => {
      const response = await retryFetch(url, {
        credentials: "include",
        headers: { Accept: "text/html" }
      });
      if (!response.ok)
        throw new Error(`Nature HTTP ${response.status} for ${url}`);
      const doc = new DOMParser().parseFromString(await response.text(), "text/html");
      if (doc.title === "Client Challenge") {
        throw new Error("Nature is completing browser verification; retry the action shortly");
      }
      return doc;
    };
    const meta = (doc, name) => doc.querySelector(`meta[name="${name}"]`)?.content.trim() ?? "";
    const metas = (doc, name) => [...doc.querySelectorAll(`meta[name="${name}"]`)].map((element) => element.content.trim()).filter(Boolean);
    const normalizeArticleInput = (value) => {
      const input = value.trim();
      let path = input;
      if (/^https?:\/\//i.test(input))
        path = new URL(input).pathname;
      path = path.replace(/^\/articles\//i, "");
      path = path.replace(/^10\.1038\//i, "");
      path = path.split(/[?#]/, 1)[0] ?? "";
      path = path.replace(/(?:_reference)?\.pdf$/i, "").replace(/^\/+|\/+$/g, "");
      if (!path || path.includes("/"))
        throw new Error(`Invalid Nature article identifier: ${value}`);
      return path;
    };
    action("searchArticles", {
      async invoke({
        query,
        author,
        title,
        journal,
        articleType,
        startYear,
        endYear,
        order = "relevance",
        cursor
      }) {
        if (!query.trim())
          throw new Error("searchArticles: query is required");
        if (startYear && endYear && startYear > endYear) {
          throw new Error("searchArticles: startYear must not be after endYear");
        }
        const page = pageCursor(cursor, 1);
        const params = new URLSearchParams({ q: query.trim(), order });
        if (author?.trim())
          params.set("author", author.trim());
        if (title?.trim())
          params.set("title", title.trim());
        if (journal?.trim())
          params.set("journal", journal.trim());
        if (articleType?.trim())
          params.set("article_type", articleType.trim());
        if (startYear || endYear)
          params.set("date_range", `${startYear ?? ""}-${endYear ?? ""}`);
        if (page > 1)
          params.set("page", String(page));
        const doc = await fetchDocument(`${ORIGIN}/search?${params}`);
        const items = [...doc.querySelectorAll('#search-article-list article[itemtype="http://schema.org/ScholarlyArticle"]')].map((element) => articleCard(element)).filter((item) => item.id && item.title && item.url);
        const resultText = cleanText(doc.querySelector('[data-test="results-data"]')?.textContent);
        const totalCount = Number.parseInt(resultText.match(/([\d,]+)\s+results/i)?.[1]?.replace(/,/g, "") ?? "0", 10);
        const nextHref = doc.querySelector('[data-test="page-next"] a[href]')?.getAttribute("href");
        const nextCursor = nextHref ? new URL(nextHref, ORIGIN).searchParams.get("page") : null;
        log(`searchArticles "${query}" page ${page}: ${items.length}/${totalCount}`);
        return { items, totalCount, nextCursor };
      }
    });
    action("getArticle", {
      async invoke({ id }) {
        const normalizedId = normalizeArticleInput(id);
        const url = `${ORIGIN}/articles/${encodeURIComponent(normalizedId)}`;
        const doc = await fetchDocument(url);
        const title = meta(doc, "citation_title") || cleanText(doc.querySelector('[data-test="article-title"]')?.textContent);
        if (!title)
          throw new Error(`getArticle: no article found for ${id}`);
        const body = doc.querySelector(".c-article-body");
        const skippedSections = new Set([
          "abstract",
          "inline recommendations",
          "author information",
          "additional information",
          "supplementary information",
          "rights and permissions",
          "about this article"
        ]);
        const abstractSection = body?.querySelector('section[data-title="Abstract"] .c-article-section__content');
        const summary = meta(doc, "dc.description") || cleanText(abstractSection?.textContent);
        const sections = [...body?.querySelectorAll("section[data-title]") ?? []].map((section) => {
          const heading = cleanText(section.getAttribute("data-title") || section.querySelector("h2")?.textContent);
          const copy = section.cloneNode(true);
          copy.querySelectorAll("script,style,svg,figure,.c-article-recommendations,.c-article-section__title").forEach((node) => node.remove());
          return { heading, text: cleanText(copy.textContent) };
        }).filter((section) => section.heading && section.text && !skippedSections.has(section.heading.toLowerCase()));
        const doi = meta(doc, "citation_doi").replace(/^doi:/i, "");
        const journal = meta(doc, "citation_journal_title");
        const articleType = meta(doc, "citation_article_type") || meta(doc, "dc.type");
        const publishedAt = meta(doc, "citation_online_date") || meta(doc, "prism.publicationDate") || meta(doc, "dc.date");
        const pdfUrl = meta(doc, "citation_pdf_url");
        const canonicalUrl = meta(doc, "prism.url") || doc.querySelector('link[rel="canonical"]')?.href || url;
        const result = {
          id: articleId(canonicalUrl) || normalizedId,
          doi: doi || null,
          title,
          authors: metas(doc, "citation_author"),
          summary: summary || null,
          subjects: metas(doc, "dc.subject"),
          articleType: articleType || null,
          publishedAt: publishedAt || null,
          journal: journal || null,
          openAccess: !!doc.querySelector('a[rel="license"], [data-test="open-access"]'),
          sections,
          url: canonicalUrl,
          pdfUrl: pdfUrl || null
        };
        log(`getArticle ${result.id}: ${result.authors.length} authors, ${sections.length} sections`);
        return result;
      }
    });
    action("listJournals", {
      async invoke() {
        const doc = await fetchDocument(`${ORIGIN}/siteindex`);
        const items = [...doc.querySelectorAll('#journals-az li a[href^="/"]')].map((link) => {
          const url = absoluteUrl(link.getAttribute("href"));
          const id = new URL(url).pathname.split("/").filter(Boolean)[0] ?? "";
          return { id, name: cleanText(link.textContent), url };
        }).filter((item) => item.id && item.name).filter((item, index, all) => all.findIndex((candidate) => candidate.id === item.id) === index);
        log(`listJournals: ${items.length} journals`);
        return { items, nextCursor: null };
      }
    });
    action("getJournal", {
      async invoke({ id }) {
        const normalizedId = id.trim().replace(/^\/+|\/+$/g, "");
        if (!normalizedId || normalizedId.includes("/"))
          throw new Error(`Invalid Nature journal identifier: ${id}`);
        const requestedUrl = `${ORIGIN}/${encodeURIComponent(normalizedId)}/`;
        const doc = await fetchDocument(requestedUrl);
        const name = doc.querySelector('meta[property="og:title"]')?.content.trim() || cleanText(doc.querySelector('footer [itemprop="name"]')?.textContent);
        if (!name)
          throw new Error(`getJournal: no journal found for ${id}`);
        const canonicalUrl = doc.querySelector('link[rel="canonical"]')?.href || requestedUrl;
        const groups = [...doc.querySelectorAll('section[data-track-component$=" grid"]')].map((section) => {
          const items = [...section.querySelectorAll('article[itemtype="http://schema.org/ScholarlyArticle"]')].map((element) => articleCard(element, name)).filter((item) => item.id && item.title && item.url);
          const heading = cleanText(section.querySelector('.c-section-heading [data-test="title"], .c-section-heading h2, h2')?.textContent) || cleanText(section.getAttribute("data-track-component")).replace(/\s+grid$/i, "");
          return { id: section.id, heading, items };
        }).filter((group) => group.id && group.heading && group.items.length > 0);
        const issns = [...doc.querySelectorAll('[itemprop="issn"]')].map((element) => cleanText(element.textContent)).filter(Boolean).filter((value, index, all) => all.indexOf(value) === index);
        const description = meta(doc, "description");
        log(`getJournal ${normalizedId}: ${groups.length} content groups`);
        return {
          id: normalizedId,
          name,
          description: description || null,
          issns,
          groups,
          url: canonicalUrl
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

  installService("www.nature.com", actions_default);
})();
