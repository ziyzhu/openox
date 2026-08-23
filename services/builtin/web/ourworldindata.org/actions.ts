import type { ActionInstaller } from "../action.ts";
import { pageCursor } from "../../../action-lib.ts";

const install: ActionInstaller = ({ action, retryFetch, log }) => {
  const ORIGIN = "https://ourworldindata.org";
  const ALGOLIA_APP_ID = "ASCB5XMYF2";
  const ALGOLIA_API_KEY = "bafe9c4659e5657bf750a38fbee5c269";
  const ALGOLIA_URL =
    `https://${ALGOLIA_APP_ID.toLowerCase()}-dsn.algolia.net/1/indexes/*/queries` +
    `?x-algolia-api-key=${ALGOLIA_API_KEY}&x-algolia-application-id=${ALGOLIA_APP_ID}`;

  const algolia = async (req: Record<string, unknown>) => {
    const res = await retryFetch(ALGOLIA_URL, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ requests: [req] }),
    });
    if (!res.ok) throw new Error(`algolia ${res.status}`);
    const json = await res.json();
    const result = json?.results?.[0];
    if (!result) throw new Error("algolia: empty result");
    return result as { hits: any[]; nbPages: number; page: number };
  };

  const pageUrl = (type: string, slug: string) => {
    if (type === "data-insight") return `${ORIGIN}/data-insights/${slug}`;
    if (type === "explorerView" || type === "explorer") return `${ORIGIN}/explorers/${slug}`;
    if (type === "chart") return `${ORIGIN}/grapher/${slug}`;
    return `${ORIGIN}/${slug}`;
  };

  const paginate = (result: { hits: any[]; nbPages: number; page: number }) =>
    result.page + 1 < result.nbPages ? String(result.page + 1) : null;

  action("search", {
    async invoke({ query, cursor, limit = 20 } = {}) {
      const result = await algolia({
        indexName: "pages",
        query: query ?? "",
        attributesToRetrieve: ["title", "slug", "type", "date", "excerpt", "authors"],
        hitsPerPage: limit,
        page: pageCursor(cursor, 0),
      });
      const items = result.hits.map((h) => ({
        type: h.type ?? "",
        title: h.title ?? "",
        slug: h.slug ?? "",
        url: pageUrl(h.type ?? "", h.slug ?? ""),
        date: h.date ?? null,
        excerpt: h.excerpt ?? null,
        authors: Array.isArray(h.authors) ? h.authors : [],
      }));
      return { items, nextCursor: paginate(result) };
    },
  });

  action("searchCharts", {
    async invoke({ query, cursor, limit = 20 } = {}) {
      const result = await algolia({
        indexName: "explorer-views-and-charts",
        query: query ?? "",
        attributesToRetrieve: [
          "title", "containerTitle", "subtitle", "slug",
          "variantName", "type", "availableEntities",
        ],
        hitsPerPage: limit,
        page: pageCursor(cursor, 0),
      });
      const items = result.hits.map((h) => ({
        type: h.type ?? "",
        title: h.title ?? "",
        subtitle: h.subtitle ?? null,
        variantName: h.variantName ?? null,
        slug: h.slug ?? "",
        url: pageUrl(h.type ?? "", h.slug ?? ""),
        availableEntities: Array.isArray(h.availableEntities) ? h.availableEntities : [],
      }));
      return { items, nextCursor: paginate(result) };
    },
  });

  action("listLatest", {
    async invoke({ cursor, limit = 20 } = {}) {
      const result = await algolia({
        indexName: "pages-chronological",
        query: "",
        filters: "type:article OR type:data-insight OR type:announcement",
        hitsPerPage: limit,
        page: pageCursor(cursor, 0),
      });
      const items = result.hits.map((h) => ({
        type: h.type ?? "",
        title: h.title ?? "",
        slug: h.slug ?? "",
        url: pageUrl(h.type ?? "", h.slug ?? ""),
        date: h.date ?? null,
        authors: Array.isArray(h.authors) ? h.authors : [],
      }));
      return { items, nextCursor: paginate(result) };
    },
  });

  action("getChartData", {
    async invoke({ slug, entities } = {}) {
      try {
        if (!slug) throw new Error("getChartData: slug is required");
        const params = new URLSearchParams({ version: "1", variant: "medium" });
        if (entities) params.set("entities", `~${entities}`);
        const url = `${ORIGIN}/grapher/${encodeURIComponent(slug)}.search-result.json?${params}`;
        const res = await retryFetch(url, { credentials: "include" });
        if (!res.ok) throw new Error(`getChartData: ${slug} HTTP ${res.status}`);
        const data = await res.json();
        const rows = Array.isArray(data?.dataTable?.rows)
          ? data.dataTable.rows.map((r: any) => ({
              entity: r.seriesName ?? r.label ?? "",
              value: r.value ?? null,
              time: r.time ?? null,
            }))
          : [];
        const vd = data?.valueDisplay ?? {};
        return {
          slug,
          title: data?.title ?? "",
          unit: data?.unit ?? null,
          source: data?.source ?? null,
          url: `${ORIGIN}/grapher/${slug}`,
          latest: vd.endValue
            ? { entity: vd.entityName ?? "", value: vd.endValue, time: vd.time ?? null }
            : null,
          rows,
        };
      } catch (e: any) {
        log(`getChartData failed: ${e?.message ?? e}`);
        throw e;
      }
    },
  });
};

export default install;
