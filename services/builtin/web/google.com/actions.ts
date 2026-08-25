import type { ActionInstaller } from "@openox/service-sdk/action";
import { cleanText } from "@openox/service-sdk/action-lib";

const ORIGIN = "https://www.google.com";

type ThumbnailResolver = (image: HTMLImageElement) => string | null;

const normalizedUrl = (value: string): string | null => {
  try {
    const url = new URL(value, ORIGIN);
    const redirected = url.hostname.endsWith(".google.com") && url.pathname === "/url"
      ? url.searchParams.get("q")
      : null;
    const resolved = redirected ? new URL(redirected) : url;
    return resolved.protocol === "http:" || resolved.protocol === "https:" ? resolved.href : null;
  } catch {
    return null;
  }
};

const timestamp = (value: string | null): string | null => {
  const seconds = Number(value);
  if (!Number.isFinite(seconds) || seconds <= 0) return null;
  const date = new Date(seconds * 1000);
  return Number.isFinite(date.getTime()) ? date.toISOString() : null;
};

const boundedLimit = (value: unknown): number => {
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isInteger(parsed) ? Math.min(20, Math.max(1, parsed)) : 10;
};

const siteOf = (url: string): string => {
  try {
    return new URL(url).hostname.toLowerCase();
  } catch {
    return "";
  }
};

export function parseNewsResults(doc: ParentNode, limit: number) {
  const items = [] as Array<{
    title: string;
    url: string;
    site: string;
    source: string;
    publishedAt: string | null;
    publishedText: string;
  }>;
  const seen = new Set<string>();
  const anchors = [...doc.querySelectorAll<HTMLAnchorElement>("a[jsname='YKoRaf'][href]")];
  for (const heading of doc.querySelectorAll<HTMLElement>("h3")) {
    const anchor = heading.closest<HTMLAnchorElement>("a[href]");
    if (anchor && !anchors.includes(anchor)) anchors.push(anchor);
  }
  for (const anchor of anchors) {
    const url = normalizedUrl(anchor.href);
    const title = cleanText((anchor.querySelector("[role='heading']") ?? anchor.querySelector("h3"))?.textContent);
    if (!url || !title || seen.has(url)) continue;
    const site = siteOf(url);
    const sourceElement = anchor.querySelector(".MgUUmf.NUnG9d > span:last-child")
      ?? anchor.querySelector(".KogRLb")
      ?? anchor.querySelector(".BamJPe");
    const source = cleanText(sourceElement?.textContent)
      .split("›")[0]?.trim() || site;
    const publishedAt = timestamp(anchor.querySelector("[data-ts]")?.getAttribute("data-ts") ?? null);
    const publishedText = cleanText((anchor.querySelector("[data-ts]") ?? anchor.querySelector(".UK5aid"))?.textContent);
    seen.add(url);
    items.push({ title, url, site, source, publishedAt, publishedText });
    if (items.length === limit) break;
  }
  return items;
}

export function parseImageResults(doc: ParentNode, limit: number, thumbnailFor: ThumbnailResolver) {
  const items = [] as Array<{
    title: string;
    sourceUrl: string;
    site: string;
    thumbnailUrl: string;
  }>;
  const seen = new Set<string>();
  const append = (sourceUrl: string | null, title: string, image: HTMLImageElement | null) => {
    const thumbnailUrl = image ? thumbnailFor(image) : null;
    if (!sourceUrl || !title || !thumbnailUrl || seen.has(`${sourceUrl}\n${thumbnailUrl}`)) return;
    seen.add(`${sourceUrl}\n${thumbnailUrl}`);
    items.push({ title, sourceUrl, site: siteOf(sourceUrl), thumbnailUrl });
  };
  for (const root of doc.querySelectorAll<HTMLElement>("[jsname='dTDiAc'][data-lpage]")) {
    const sourceUrl = normalizedUrl(root.getAttribute("data-lpage") ?? "");
    const image = root.querySelector<HTMLImageElement>("img[alt][id]");
    const title = cleanText(image?.alt);
    append(sourceUrl, title, image);
    if (items.length === limit) break;
  }
  if (items.length < limit) {
    for (const row of doc.querySelectorAll<HTMLElement>("tbody:has(img.DS1iW)")) {
      const image = row.querySelector<HTMLImageElement>("img.DS1iW");
      const anchor = image?.closest<HTMLAnchorElement>("a[href]");
      const sourceUrl = normalizedUrl(anchor?.href ?? "");
      const title = cleanText(row.querySelector(".qXLe6d.x3G5ab .fYyStc")?.textContent);
      append(sourceUrl, title, image);
      if (items.length === limit) break;
    }
  }
  return items;
}

export function parseVideoResults(doc: ParentNode, limit: number, thumbnailFor: ThumbnailResolver) {
  const items = [] as Array<{
    title: string;
    url: string;
    site: string;
    source: string;
    creator: string | null;
    snippet: string;
    duration: string;
    publishedText: string;
    thumbnailUrl: string | null;
  }>;
  const seen = new Set<string>();
  for (const heading of doc.querySelectorAll<HTMLElement>("h3")) {
    const anchor = heading.closest<HTMLAnchorElement>("a[href]");
    const url = normalizedUrl(anchor?.href ?? "");
    const title = cleanText(heading.textContent);
    if (!url || !title || seen.has(url)) continue;
    const container = heading.closest<HTMLElement>("div[data-hveid]")
      ?? heading.closest<HTMLElement>(".Gx5Zad");
    if (!container) continue;
    const metadata = [...container.querySelectorAll<HTMLElement>(".gqF9jc > span")]
      .map((element) => cleanText(element.textContent))
      .filter((value) => value && value !== "·");
    const site = siteOf(url);
    const basicSource = cleanText(container.querySelector(".BamJPe")?.textContent).split("›")[0]?.trim() || "";
    const detailText = cleanText(container.querySelector(".H66NU")?.textContent);
    const image = container.querySelector<HTMLImageElement>(".iHxmLe img[id], img[id]");
    seen.add(url);
    items.push({
      title,
      url,
      site,
      source: metadata[0] || basicSource || site,
      creator: metadata.length >= 3 ? metadata[1] ?? null : null,
      snippet: cleanText(container.querySelector(".ITZIwc")?.textContent) || detailText,
      duration: cleanText(container.querySelector(".kSFuOd span")?.textContent)
        || detailText.match(/Duration:\s*([0-9]+(?::[0-9]{2}){1,2})/)?.[1] || "",
      publishedText: metadata.at(-1) ?? cleanText(container.querySelector(".H66NU .UK5aid")?.textContent),
      thumbnailUrl: image ? thumbnailFor(image) : null,
    });
    if (items.length === limit) break;
  }
  return items;
}

const install: ActionInstaller = ({ action, retryFetch, log }) => {
  const ensureSearchPage = (doc: Document, responseUrl: string): Document => {
    const host = new URL(responseUrl, ORIGIN).hostname;
    if (host === "sorry.google.com" || doc.querySelector("form#captcha-form, form[action*='/sorry/']")) {
      throw new Error("Google requires a CAPTCHA");
    }
    if (host === "consent.google.com" || doc.querySelector("form[action*='consent.google.com']")) {
      throw new Error("Google requires consent");
    }
    if (host !== "google.com" && !host.endsWith(".google.com")) throw new Error(`Unexpected Google host ${host}`);
    return doc;
  };

  const isExplicitlyEmpty = (doc: Document) => {
    const text = cleanText(doc.querySelector("#topstuff")?.textContent);
    return /did not match any documents|no results found/i.test(text)
      || (doc.location.pathname === "/search" && !!doc.querySelector("#main")
        && !doc.querySelector(".Gx5Zad:not(#st-card), .MjjYud"));
  };

  const thumbnailResolver = (): ThumbnailResolver => {
    const google = (window as any).google;
    return (image) => {
      const candidate = google?.pim?.[image.id] ?? google?.ldi?.[image.id]
        ?? image.currentSrc ?? image.getAttribute("data-src") ?? image.getAttribute("src");
      return typeof candidate === "string" && /^https:\/\//.test(candidate) ? candidate : null;
    };
  };

  action("listSuggestions", {
    async invoke({ query } = {}) {
      if (!query) throw new Error("listSuggestions: query is required");
      const params = new URLSearchParams({ client: "firefox", q: query, hl: "en" });
      const response = await retryFetch(`/complete/s?${params}`, { credentials: "include" });
      if (!response.ok) throw new Error(`listSuggestions HTTP ${response.status}`);
      const text = await response.text();
      const json = JSON.parse(text.slice(text.indexOf("[")));
      const items: string[] = Array.isArray(json?.[1]) ? json[1].filter((value: unknown) => typeof value === "string") : [];
      return { items, nextCursor: null };
    },
  });

  action("searchNews", {
    async invoke({ query, limit } = {}) {
      if (!query) throw new Error("searchNews: query is required");
      const doc = ensureSearchPage(document, location.href);
      const items = parseNewsResults(doc, boundedLimit(limit));
      if (!items.length && !isExplicitlyEmpty(doc)) throw new Error("Google news result markup was not recognized");
      const nextUrl = normalizedUrl(doc.querySelector("a#pnnext[href]")?.getAttribute("href") ?? "");
      const nextCursor = nextUrl ? new URL(nextUrl).searchParams.get("start") : null;
      log(`searchNews queryChars=${query.length} items=${items.length}`);
      return { items, nextCursor };
    },
  });

  action("searchImages", {
    async invoke({ query, limit } = {}) {
      if (!query) throw new Error("searchImages: query is required");
      const doc = ensureSearchPage(document, location.href);
      const items = parseImageResults(doc, boundedLimit(limit), thumbnailResolver());
      if (!items.length && !isExplicitlyEmpty(doc)) throw new Error("Google image result markup was not recognized");
      log(`searchImages queryChars=${query.length} items=${items.length}`);
      return { items, nextCursor: null };
    },
  });

  action("searchVideos", {
    async invoke({ query, limit } = {}) {
      if (!query) throw new Error("searchVideos: query is required");
      const doc = ensureSearchPage(document, location.href);
      const items = parseVideoResults(doc, boundedLimit(limit), thumbnailResolver());
      if (!items.length && !isExplicitlyEmpty(doc)) throw new Error("Google video result markup was not recognized");
      log(`searchVideos queryChars=${query.length} items=${items.length}`);
      return { items, nextCursor: null };
    },
  });
};

export default install;
