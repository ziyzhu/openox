import type { ActionInstaller } from "@openox/service-sdk/action";
import { cleanText, pageCursor } from "@openox/service-sdk/action-lib";

const ORIGIN = "https://www.nature.com";
const START_URL = `${ORIGIN}/search?q=zzzzunlikelyqueryzzzz`;

const absoluteUrl = (value: string | null) => value ? new URL(value, ORIGIN).href : "";

const articleId = (url: string) => {
  const match = new URL(url, ORIGIN).pathname.match(/^\/articles\/([^/]+)/);
  return match ? decodeURIComponent(match[1] ?? "") : "";
};

const articleCard = (element: Element, fallbackJournal: string | null = null) => {
  const link = element.querySelector<HTMLAnchorElement>('.c-card__title a[href*="/articles/"]');
  const url = absoluteUrl(link?.getAttribute("href") ?? null);
  const summary = cleanText(element.querySelector('[data-test="article-description"]')?.textContent);
  const articleType = cleanText(element.querySelector('[data-test="article.type"]')?.textContent);
  const publishedAt = element.querySelector<HTMLTimeElement>('time[itemprop="datePublished"]')?.dateTime ?? "";
  const journal = cleanText(element.querySelector('[data-test="journal-title-and-link"]')?.textContent) || fallbackJournal;
  return {
    id: articleId(url),
    title: cleanText(link?.textContent),
    authors: [...element.querySelectorAll('[itemprop="creator"] [itemprop="name"]')]
      .map((author) => cleanText(author.textContent))
      .filter(Boolean),
    summary: summary || null,
    articleType: articleType || null,
    publishedAt: publishedAt || null,
    journal,
    openAccess: !!element.querySelector('[data-test="open-access"]'),
    url,
  };
};

const install: ActionInstaller = ({ action, retryFetch, log }) => {
  const fetchDocument = async (url: string) => {
    const response = await retryFetch(url, {
      credentials: "include",
      headers: { Accept: "text/html" },
    });
    if (!response.ok) throw new Error(`Nature HTTP ${response.status} for ${url}`);
    const doc = new DOMParser().parseFromString(await response.text(), "text/html");
    if (doc.title === "Client Challenge") {
      throw new Error("Nature is completing browser verification; retry the action shortly");
    }
    return doc;
  };

  const meta = (doc: Document, name: string) =>
    doc.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)?.content.trim() ?? "";

  const metas = (doc: Document, name: string) =>
    [...doc.querySelectorAll<HTMLMetaElement>(`meta[name="${name}"]`)]
      .map((element) => element.content.trim())
      .filter(Boolean);

  const normalizeArticleInput = (value: string) => {
    const input = value.trim();
    let path = input;
    if (/^https?:\/\//i.test(input)) path = new URL(input).pathname;
    path = path.replace(/^\/articles\//i, "");
    path = path.replace(/^10\.1038\//i, "");
    path = path.split(/[?#]/, 1)[0] ?? "";
    path = path.replace(/(?:_reference)?\.pdf$/i, "").replace(/^\/+|\/+$/g, "");
    if (!path || path.includes("/")) throw new Error(`Invalid Nature article identifier: ${value}`);
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
      cursor,
    }: {
      query: string;
      author?: string;
      title?: string;
      journal?: string;
      articleType?: string;
      startYear?: number;
      endYear?: number;
      order?: string;
      cursor?: string;
    }) {
      if (!query.trim()) throw new Error("searchArticles: query is required");
      if (startYear && endYear && startYear > endYear) {
        throw new Error("searchArticles: startYear must not be after endYear");
      }
      const page = pageCursor(cursor, 1);
      const params = new URLSearchParams({ q: query.trim(), order });
      if (author?.trim()) params.set("author", author.trim());
      if (title?.trim()) params.set("title", title.trim());
      if (journal?.trim()) params.set("journal", journal.trim());
      if (articleType?.trim()) params.set("article_type", articleType.trim());
      if (startYear || endYear) params.set("date_range", `${startYear ?? ""}-${endYear ?? ""}`);
      if (page > 1) params.set("page", String(page));
      const doc = await fetchDocument(`${ORIGIN}/search?${params}`);
      const items = [...doc.querySelectorAll('#search-article-list article[itemtype="http://schema.org/ScholarlyArticle"]')]
        .map((element) => articleCard(element))
        .filter((item) => item.id && item.title && item.url);
      const resultText = cleanText(doc.querySelector('[data-test="results-data"]')?.textContent);
      const totalCount = Number.parseInt(resultText.match(/([\d,]+)\s+results/i)?.[1]?.replace(/,/g, "") ?? "0", 10);
      const nextHref = doc.querySelector<HTMLAnchorElement>('[data-test="page-next"] a[href]')?.getAttribute("href");
      const nextCursor = nextHref ? new URL(nextHref, ORIGIN).searchParams.get("page") : null;
      log(`searchArticles "${query}" page ${page}: ${items.length}/${totalCount}`);
      return { items, totalCount, nextCursor };
    },
  });

  action("getArticle", {
    async invoke({ id }: { id: string }) {
      const normalizedId = normalizeArticleInput(id);
      const url = `${ORIGIN}/articles/${encodeURIComponent(normalizedId)}`;
      const doc = await fetchDocument(url);
      const title = meta(doc, "citation_title") || cleanText(doc.querySelector('[data-test="article-title"]')?.textContent);
      if (!title) throw new Error(`getArticle: no article found for ${id}`);
      const body = doc.querySelector(".c-article-body");
      const skippedSections = new Set([
        "abstract",
        "inline recommendations",
        "author information",
        "additional information",
        "supplementary information",
        "rights and permissions",
        "about this article",
      ]);
      const abstractSection = body?.querySelector('section[data-title="Abstract"] .c-article-section__content');
      const summary = meta(doc, "dc.description") || cleanText(abstractSection?.textContent);
      const sections = [...(body?.querySelectorAll<HTMLElement>("section[data-title]") ?? [])]
        .map((section) => {
          const heading = cleanText(section.getAttribute("data-title") || section.querySelector("h2")?.textContent);
          const copy = section.cloneNode(true) as HTMLElement;
          copy.querySelectorAll("script,style,svg,figure,.c-article-recommendations,.c-article-section__title").forEach((node) => node.remove());
          return { heading, text: cleanText(copy.textContent) };
        })
        .filter((section) => section.heading && section.text && !skippedSections.has(section.heading.toLowerCase()));
      const doi = meta(doc, "citation_doi").replace(/^doi:/i, "");
      const journal = meta(doc, "citation_journal_title");
      const articleType = meta(doc, "citation_article_type") || meta(doc, "dc.type");
      const publishedAt = meta(doc, "citation_online_date") || meta(doc, "prism.publicationDate") || meta(doc, "dc.date");
      const pdfUrl = meta(doc, "citation_pdf_url");
      const canonicalUrl = meta(doc, "prism.url") || doc.querySelector<HTMLLinkElement>('link[rel="canonical"]')?.href || url;
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
        pdfUrl: pdfUrl || null,
      };
      log(`getArticle ${result.id}: ${result.authors.length} authors, ${sections.length} sections`);
      return result;
    },
  });

  action("listJournals", {
    async invoke() {
      const doc = await fetchDocument(`${ORIGIN}/siteindex`);
      const items = [...doc.querySelectorAll<HTMLAnchorElement>('#journals-az li a[href^="/"]')]
        .map((link) => {
          const url = absoluteUrl(link.getAttribute("href"));
          const id = new URL(url).pathname.split("/").filter(Boolean)[0] ?? "";
          return { id, name: cleanText(link.textContent), url };
        })
        .filter((item) => item.id && item.name)
        .filter((item, index, all) => all.findIndex((candidate) => candidate.id === item.id) === index);
      log(`listJournals: ${items.length} journals`);
      return { items, nextCursor: null };
    },
  });

  action("getJournal", {
    async invoke({ id }: { id: string }) {
      const normalizedId = id.trim().replace(/^\/+|\/+$/g, "");
      if (!normalizedId || normalizedId.includes("/")) throw new Error(`Invalid Nature journal identifier: ${id}`);
      const requestedUrl = `${ORIGIN}/${encodeURIComponent(normalizedId)}/`;
      const doc = await fetchDocument(requestedUrl);
      const name = doc.querySelector<HTMLMetaElement>('meta[property="og:title"]')?.content.trim()
        || cleanText(doc.querySelector('footer [itemprop="name"]')?.textContent);
      if (!name) throw new Error(`getJournal: no journal found for ${id}`);
      const canonicalUrl = doc.querySelector<HTMLLinkElement>('link[rel="canonical"]')?.href || requestedUrl;
      const groups = [...doc.querySelectorAll<HTMLElement>('section[data-track-component$=" grid"]')]
        .map((section) => {
          const items = [...section.querySelectorAll('article[itemtype="http://schema.org/ScholarlyArticle"]')]
            .map((element) => articleCard(element, name))
            .filter((item) => item.id && item.title && item.url);
          const heading = cleanText(section.querySelector('.c-section-heading [data-test="title"], .c-section-heading h2, h2')?.textContent)
            || cleanText(section.getAttribute("data-track-component")).replace(/\s+grid$/i, "");
          return { id: section.id, heading, items };
        })
        .filter((group) => group.id && group.heading && group.items.length > 0);
      const issns = [...doc.querySelectorAll('[itemprop="issn"]')]
        .map((element) => cleanText(element.textContent))
        .filter(Boolean)
        .filter((value, index, all) => all.indexOf(value) === index);
      const description = meta(doc, "description");
      log(`getJournal ${normalizedId}: ${groups.length} content groups`);
      return {
        id: normalizedId,
        name,
        description: description || null,
        issns,
        groups,
        url: canonicalUrl,
      };
    },
  });
};

export default install;
