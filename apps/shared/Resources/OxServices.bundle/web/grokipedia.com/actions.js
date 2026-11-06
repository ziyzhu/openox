const cleanText = (value) => String(value ?? "").replace(/\s+/g, " ").trim();

const retryFetch = async (input, init) => {
  for (let attempt = 0; ; attempt++) {
    try {
      const response = await window.fetch(input, init);
      const retryable = response.status === 408 || response.status === 429 ||
        (response.status >= 500 && response.status <= 599);
      if (response.ok || !retryable || attempt >= 2) return response;
    } catch (error) {
      const message = String(error?.message ?? "");
      const retryable = message.includes("Load failed") ||
        message.includes("NetworkError") || message.includes("Failed to fetch");
      if (!retryable || attempt >= 2) throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 350 * Math.pow(2, attempt)));
  }
};

window.ox.install(({ action }) => {
  const ORIGIN = "https://grokipedia.com";

  const fetchDocument = async (path, actionId) => {
    const response = await retryFetch(ORIGIN + path, {
      method: "GET",
      credentials: "include",
      cache: "no-store",
      headers: { Accept: "text/html" },
    });
    if (!response.ok) throw new Error(`${actionId}: GET ${path} -> ${response.status}`);
    const document = new DOMParser().parseFromString(await response.text(), "text/html");
    if (!document?.documentElement) throw new Error(`${actionId}: invalid HTML response`);
    return document;
  };

  action("searchArticles", {
    async invoke({ query, cursor }) {
      query = cleanText(query);
      if (!query) throw new Error("searchArticles: query is required");
      const page = cursor ? Number(cursor) : 1;
      if (!Number.isSafeInteger(page) || page < 1) throw new Error("searchArticles: invalid cursor");
      const params = new URLSearchParams({ q: query });
      if (page > 1) params.set("page", String(page));
      const document = await fetchDocument(`/search?${params.toString()}`, "searchArticles");
      const anchors = [...document.querySelectorAll('a[data-search-result-link][data-slug]')];
      const items = anchors.map((anchor) => {
        const slug = cleanText(anchor.getAttribute("data-slug"));
        if (!slug) throw new Error("searchArticles: result missing slug");
        return {
          slug,
          title: cleanText(anchor.querySelector("h3")?.textContent) || slug.replace(/_/g, " "),
          excerpt: cleanText(anchor.getAttribute("data-search-snippet") || anchor.querySelector("p")?.textContent),
          url: new URL(anchor.getAttribute("href"), ORIGIN).href,
        };
      });
      const summary = cleanText(document.querySelector("main")?.children?.[1]?.textContent || "");
      const totalMatch = summary.match(/^([\d,]+) results? for/);
      const pageMatch = summary.match(/Page (\d+) of ([\d,]+)/);
      const total = totalMatch ? Number(totalMatch[1].replace(/,/g, "")) : (items.length === 0 ? 0 : null);
      const pageCount = pageMatch ? Number(pageMatch[2].replace(/,/g, "")) : (items.length === 0 ? 0 : null);
      const nextHref = [...document.querySelectorAll('nav a[href*="/search?"]')]
        .find((anchor) => cleanText(anchor.textContent) === "Next")?.getAttribute("href") || null;
      let nextCursor = null;
      if (nextHref) {
        const nextPage = new URL(nextHref, ORIGIN).searchParams.get("page");
        if (nextPage && /^\d+$/.test(nextPage) && Number(nextPage) > page) nextCursor = nextPage;
      }
      console.log(`searchArticles: page=${page} results=${items.length} next=${nextCursor ?? "none"}`);
      return { items, total, page, pageCount, nextCursor };
    },
  });

  const readableText = (element) => {
    const clone = element.cloneNode(true);
    for (const noise of clone.querySelectorAll("script,style,button,svg,sup,[aria-hidden='true']")) noise.remove();
    return cleanText(clone.textContent);
  };

  action("getArticle", {
    async invoke({ slug }) {
      slug = cleanText(slug);
      if (!slug || slug.includes("/") || slug.includes("?") || slug.includes("#")) {
        throw new Error("getArticle: invalid slug");
      }
      const path = `/page/${encodeURIComponent(slug)}`;
      const document = await fetchDocument(path, "getArticle");
      const article = document.querySelector("article.article-enter");
      const body = article?.querySelector(".article-body");
      const title = cleanText(article?.querySelector("h1")?.textContent);
      if (!article || !body || !title) throw new Error(`getArticle: no article content for "${slug}"`);

      const facts = [];
      const factList = article.querySelector("aside.infobox dl");
      if (factList) {
        const names = [...factList.querySelectorAll("dt")];
        const values = [...factList.querySelectorAll("dd")];
        for (let index = 0; index < Math.min(names.length, values.length); index++) {
          const name = readableText(names[index]);
          const value = readableText(values[index]);
          if (name && value) facts.push({ name, value });
        }
      }

      const sections = [{ heading: "", level: 1, parts: [] }];
      for (const child of body.children) {
        if (/^H[23]$/.test(child.tagName)) {
          sections.push({ heading: readableText(child), level: Number(child.tagName.slice(1)), parts: [] });
          continue;
        }
        const text = readableText(child);
        if (text) sections[sections.length - 1].parts.push(text);
      }
      const normalizedSections = sections
        .map((section) => ({ heading: section.heading, level: section.level, text: section.parts.join("\n\n") }))
        .filter((section) => section.text);
      if (!normalizedSections.length) throw new Error(`getArticle: empty article body for "${slug}"`);

      const factChecked = cleanText(article.querySelector("header .type-hint")?.textContent) || null;
      const canonical = document.querySelector('link[rel="canonical"]')?.getAttribute("href");
      console.log(`getArticle: slug=${slug} sections=${normalizedSections.length} facts=${facts.length}`);
      return {
        slug,
        title,
        url: canonical ? new URL(canonical, ORIGIN).href : ORIGIN + path,
        factChecked,
        facts,
        sections: normalizedSections,
      };
    },
  });
});
