import type { ActionInstaller } from "@openox/service-sdk/action";

const install: ActionInstaller = ({ action, retryFetch }) => {
  const ORIGIN = "https://en.wikipedia.org";

  const fetchJson = async (path: string) => {
    const res = await retryFetch(`${ORIGIN}${path}`, { credentials: "include" });
    if (!res.ok) throw new Error(`GET ${path} -> ${res.status}`);
    return res.json();
  };

  const stripHtml = (html: string) => {
    const doc = new DOMParser().parseFromString(html ?? "", "text/html");
    return (doc.documentElement.textContent ?? "").replace(/\s+/g, " ").trim();
  };

  const absUrl = (u?: string | null) =>
    u ? (u.startsWith("//") ? `https:${u}` : u) : null;

  const articleUrl = (key: string) =>
    `${ORIGIN}/wiki/${encodeURIComponent(key.replace(/ /g, "_"))}`;

  const searchItem = (p: any) => ({
    key: p.key,
    title: p.title,
    description: p.description ?? null,
    excerpt: stripHtml(p.excerpt ?? ""),
    url: articleUrl(p.key),
    thumbnailUrl: absUrl(p.thumbnail?.url),
  });

  const searchPage = async (query: string, limit: number) => {
    const data = await fetchJson(
      `/w/rest.php/v1/search/page?q=${encodeURIComponent(query)}&limit=${limit}`,
    );
    return { items: (data.pages ?? []).map(searchItem), nextCursor: null };
  };

  action("searchArticles", {
    async invoke({ query, limit = 10 }) {
      return await searchPage(query, limit);
    },
  });

  action("listRelatedArticles", {
    async invoke({ title, limit = 10 }) {
      return await searchPage(`morelike:${title}`, limit);
    },
  });

  action("getArticleSummary", {
    async invoke({ title }) {
      const data = await fetchJson(
        `/api/rest_v1/page/summary/${encodeURIComponent(title.replace(/ /g, "_"))}`,
      );
      return {
        key: data.titles?.canonical ?? title,
        title: data.title,
        type: data.type ?? "standard",
        description: data.description ?? null,
        extract: data.extract ?? "",
        url: data.content_urls?.desktop?.page ?? articleUrl(title),
        thumbnailUrl: absUrl(data.thumbnail?.source),
        updatedAt: data.timestamp ?? null,
      };
    },
  });

  const ARTICLE_NOISE =
    "style,script,table,figure,img,sup.reference,.mw-editsection,.reflist,.refbegin,.mw-references-wrap,ol.references,.navbox,.sidebar,.shortdescription,.hatnote";

  action("getArticle", {
    async invoke({ title }) {
      const res = await retryFetch(articleUrl(title), { credentials: "include" });
      if (!res.ok) throw new Error(`getArticle: "${title}" -> ${res.status}`);
      const doc = new DOMParser().parseFromString(await res.text(), "text/html");
      const root = doc.querySelector("#mw-content-text .mw-parser-output");
      if (!root) throw new Error(`getArticle: no article content for "${title}"`);
      for (const el of root.querySelectorAll(ARTICLE_NOISE)) el.remove();

      const text = (el: Element | null) =>
        (el?.textContent ?? "").replace(/\s+/g, " ").trim();
      const sections = [{ heading: "", parts: [] as string[] }];
      for (const child of root.children) {
        const headingEl = child.classList.contains("mw-heading")
          ? child.querySelector("h2,h3,h4")
          : /^H[234]$/.test(child.tagName) ? child : null;
        if (headingEl) {
          sections.push({ heading: text(headingEl), parts: [] });
          continue;
        }
        const t = text(child);
        if (t) sections[sections.length - 1].parts.push(t);
      }

      return {
        title: text(doc.querySelector("#firstHeading")) || title,
        url:
          doc.querySelector('link[rel="canonical"]')?.getAttribute("href") ??
          articleUrl(title),
        sections: sections
          .map((s) => ({ heading: s.heading, text: s.parts.join("\n\n") }))
          .filter((s) => s.text),
      };
    },
  });
};

export default install;
