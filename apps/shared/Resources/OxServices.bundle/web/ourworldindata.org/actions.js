const pageCursor = (value, firstPage) =>
  Math.max(firstPage, Number.parseInt(value ?? String(firstPage), 10) || firstPage);

const retryFetch = async (input, init, options) => {
  const retries = options?.retries ?? 3;
  const delay = options?.delay ?? 400;
  const factor = options?.factor ?? 2;
  for (let attempt = 0; ; attempt++) {
    try {
      const response = await window.fetch(input, init);
      const retryable = response.status === 408 || response.status === 429
        || (response.status >= 500 && response.status <= 599);
      if (response.ok || !retryable || attempt >= retries) return response;
      console.log(`retryFetch: status ${response.status}, attempt ${attempt + 1}/${retries}`);
    } catch (error) {
      const message = String(error?.message ?? "");
      const retryable = message.includes("Load failed")
        || message.includes("NetworkError")
        || message.includes("Failed to fetch");
      if (!retryable || attempt >= retries) throw error;
      console.log(`retryFetch: network ${JSON.stringify(message)}, attempt ${attempt + 1}/${retries}`);
    }
    await new Promise(resolve => setTimeout(resolve, delay * Math.pow(factor, attempt)));
  }
};

window.ox.install(({ action }) => {
    const ORIGIN = "https://ourworldindata.org";
    const ALGOLIA_APP_ID = "ASCB5XMYF2";
    const ALGOLIA_API_KEY = "bafe9c4659e5657bf750a38fbee5c269";
    const ALGOLIA_URL = `https://${ALGOLIA_APP_ID.toLowerCase()}-dsn.algolia.net/1/indexes/*/queries` +
        `?x-algolia-api-key=${ALGOLIA_API_KEY}&x-algolia-application-id=${ALGOLIA_APP_ID}`;
    const algolia = async (req) => {
        const res = await retryFetch(ALGOLIA_URL, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ requests: [req] }),
        });
        if (!res.ok)
            throw new Error(`algolia ${res.status}`);
        const json = await res.json();
        const result = json?.results?.[0];
        if (!result)
            throw new Error("algolia: empty result");
        return result;
    };
    const pageUrl = (type, slug) => {
        if (type === "data-insight")
            return `${ORIGIN}/data-insights/${slug}`;
        if (type === "explorerView" || type === "explorer")
            return `${ORIGIN}/explorers/${slug}`;
        if (type === "chart")
            return `${ORIGIN}/grapher/${slug}`;
        return `${ORIGIN}/${slug}`;
    };
    const paginate = (result) => result.page + 1 < result.nbPages ? String(result.page + 1) : null;
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
    action("getChartTimeSeries", {
        async invoke({ slug, entities, startDate, endDate, limit = 200 }) {
            if (!Array.isArray(entities) || entities.length < 1 || entities.length > 20) throw new Error("getChartTimeSeries: entities must contain 1..20 entries");
            const date = value => {
                const normalized = /^\d{4}$/.test(value) ? value + "-01-01" : value;
                const time = Date.parse(normalized + "T00:00:00Z");
                if (!Number.isFinite(time) || new Date(time).toISOString().slice(0, 10) !== normalized) throw new Error("Invalid date");
                return normalized;
            };
            const start = date(startDate);
            const end = /^\d{4}$/.test(endDate) ? endDate + "-12-31" : date(endDate);
            if (start > end) throw new Error("startDate must not exceed endDate");
            const url = ORIGIN + "/grapher/" + encodeURIComponent(slug);
            const suffix = "?v=1&csvType=full&useColumnShortNames=false";
            const csvUrl = url + ".csv" + suffix;
            const metadataUrl = url + ".metadata.json" + suffix;
            const response = await retryFetch(csvUrl, { credentials: "omit" });
            if (!response.ok) throw new Error("Historical CSV HTTP " + response.status);
            const reader = response.body.getReader();
            const decoder = new TextDecoder();
            let csv = "", bytes = 0;
            for (;;) {
                const chunk = await reader.read();
                if (chunk.done) break;
                bytes += chunk.value.byteLength;
                if (bytes > 8 * 1024 * 1024) { await reader.cancel(); throw new Error("Historical CSV exceeds 8 MiB limit"); }
                csv += decoder.decode(chunk.value, { stream: true });
            }
            csv += decoder.decode();
            const records = [];
            let row = [], field = "", quoted = false;
            for (let index = 0; index < csv.length; index++) {
                const char = csv[index];
                if (char === '"') {
                    if (quoted && csv[index + 1] === '"') { field += '"'; index++; }
                    else quoted = !quoted;
                } else if (!quoted && (char === "," || char === "\n")) {
                    row.push(field.replace(/\r$/, "")); field = "";
                    if (char === "\n") { records.push(row); row = []; }
                } else field += char;
            }
            if (quoted) throw new Error("Historical CSV contains an unterminated field");
            if (field || row.length) { row.push(field.replace(/\r$/, "")); records.push(row); }
            const headers = records.shift();
            if (headers?.[0] !== "Entity" || headers?.[1] !== "Code" || headers?.[2] !== "Year" || headers.length < 4 || headers.length > 23) throw new Error("Unsupported historical CSV: expected Entity, Code, Year and at most 20 measures");
            const metaResponse = await retryFetch(metadataUrl, { credentials: "omit" });
            if (!metaResponse.ok) throw new Error("Historical metadata HTTP " + metaResponse.status);
            const metaText = await metaResponse.text();
            if (metaText.length > 1024 * 1024) throw new Error("Historical metadata exceeds 1 MiB limit");
            const meta = JSON.parse(metaText);
            const columns = meta.columns ?? {};
            const metadata = Object.values(columns);
            const series = headers.slice(3).map(column => {
                const item = columns[column] ?? (metadata.length === 1 && headers.length === 4 ? metadata[0] : {});
                return { column, indicatorId: item.owidVariableId ?? null, unit: item.unit ?? null, shortUnit: item.shortUnit ?? null,
                    source: item.citationShort ?? meta.chart?.citation ?? null, coverage: item.timespan ?? null, updatedAt: item.lastUpdated ?? null };
            });
            const wanted = new Set(entities.map(value => value.toLowerCase()));
            const rows = [];
            let matchedRows = 0, first = null, last = null;
            for (const record of records) {
                if (record.length === 1 && !record[0]) continue;
                if (record.length !== headers.length || !/^-?\d+$/.test(record[2])) throw new Error("Unexpected historical CSV row");
                const time = record[2];
                if (first === null || Number(time) < Number(first)) first = time;
                if (last === null || Number(time) > Number(last)) last = time;
                if (!wanted.has(record[0].toLowerCase()) && !wanted.has(record[1].toLowerCase())) continue;
                const day = time.padStart(4, "0") + "-01-01";
                if (day < start || day > end) continue;
                for (let col = 3; col < headers.length; col++) {
                    const raw = record[col];
                    const value = raw === "" ? null : Number(raw);
                    if (value !== null && !Number.isFinite(value)) throw new Error("Non-numeric historical value");
                    matchedRows++;
                    if (rows.length < limit) rows.push({ entity: record[0], code: record[1] || null, time, column: headers[col], value });
                }
            }
            return { slug, title: meta.chart?.title ?? slug, url, csvUrl, metadataUrl, timePrecision: "year", coverage: { start: first, end: last },
                matchedRows, returnedRows: rows.length, truncated: matchedRows > rows.length, complete: matchedRows === rows.length, series, rows };
        },
    });
    action("getChartData", {
        async invoke({ slug, entities } = {}) {
            try {
                if (!slug)
                    throw new Error("getChartData: slug is required");
                const params = new URLSearchParams({ version: "1", variant: "medium" });
                if (entities)
                    params.set("entities", `~${entities}`);
                const url = `${ORIGIN}/grapher/${encodeURIComponent(slug)}.search-result.json?${params}`;
                const res = await retryFetch(url, { credentials: "include" });
                if (!res.ok)
                    throw new Error(`getChartData: ${slug} HTTP ${res.status}`);
                const data = await res.json();
                const rows = Array.isArray(data?.dataTable?.rows)
                    ? data.dataTable.rows.map((r) => ({
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
            }
            catch (e) {
                console.log(`getChartData failed: ${e?.message ?? e}`);
                throw e;
            }
        },
    });
});
