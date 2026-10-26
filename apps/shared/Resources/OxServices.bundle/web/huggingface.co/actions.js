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
    const ORIGIN = "https://huggingface.co";
    const fetchJson = async (path) => {
        const response = await retryFetch(`${ORIGIN}${path}`, {
            credentials: "include",
            headers: { Accept: "application/json" },
        });
        if (!response.ok)
            throw new Error(`GET ${path} -> ${response.status}`);
        return response.json();
    };
    const nextPage = (page, pageSize, total) => (page + 1) * pageSize < total ? String(page + 1) : null;
    action("listModels", {
        async invoke({ library, cursor, query: search }) {
            const page = pageCursor(cursor, 0);
            const query = new URLSearchParams({
                p: String(page),
                sort: "trending",
                withCount: "true",
            });
            if (library)
                query.set("library", library);
            if (search) query.set("search", search);
            const data = await fetchJson(`/models-json?${query}`);
            const models = data.models ?? [];
            console.log(`listModels: page ${page}, ${models.length} models`);
            return {
                items: models.map((model) => ({
                    id: model.id,
                    author: model.author ?? null,
                    task: model.pipeline_tag ?? null,
                    downloads: model.downloads ?? 0,
                    likes: model.likes ?? 0,
                    parameters: model.numParameters ?? null,
                    gated: !!model.gated,
                    updatedAt: model.lastModified ?? null,
                    url: `${ORIGIN}/${model.id}`,
                })),
                nextCursor: nextPage(data.pageIndex ?? page, data.numItemsPerPage ?? models.length, data.numTotalItems ?? models.length),
            };
        },
    });
    action("listDatasets", {
        async invoke({ cursor, query: search }) {
            const page = pageCursor(cursor, 0);
            const query = new URLSearchParams({
                p: String(page),
                sort: "trending",
                withCount: "true",
            });
            if (search) query.set("search", search);
            const data = await fetchJson(`/datasets-json?${query}`);
            const datasets = data.datasets ?? [];
            console.log(`listDatasets: page ${page}, ${datasets.length} datasets`);
            return {
                items: datasets.map((dataset) => ({
                    id: dataset.id,
                    author: dataset.author ?? null,
                    downloads: dataset.downloads ?? 0,
                    likes: dataset.likes ?? 0,
                    gated: !!dataset.gated,
                    benchmark: !!dataset.isBenchmark,
                    updatedAt: dataset.lastModified ?? null,
                    url: `${ORIGIN}/datasets/${dataset.id}`,
                })),
                nextCursor: nextPage(data.pageIndex ?? page, data.numItemsPerPage ?? datasets.length, data.numTotalItems ?? datasets.length),
            };
        },
    });
    const repositoryUrl = (kind, id) => {
        if (!["model", "dataset"].includes(kind) || !/^[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+$/.test(id)) throw new Error("Invalid repository kind or id");
        return ORIGIN + (kind === "dataset" ? "/datasets/" : "/") + id;
    };
    const fetchPage = async url => {
        const response = await retryFetch(url, { credentials: "omit" });
        if (!response.ok) throw new Error("Repository page HTTP " + response.status);
        const text = await response.text();
        if (text.length > 6 * 1024 * 1024) throw new Error("Repository HTML exceeds 6 MiB limit");
        return new DOMParser().parseFromString(text, "text/html");
    };
    const component = (document, name) => {
        const element = document.querySelector('[data-target="' + name + '"]');
        if (!element) throw new Error("Public component unavailable: " + name);
        return JSON.parse(element.getAttribute("data-props") || "{}");
    };
    const repositoryHeader = (document, kind, id) => {
        const data = component(document, kind === "model" ? "ModelHeader" : "DatasetHeader");
        const repo = kind === "model" ? data.model : data.dataset;
        if (repo?.id !== id) throw new Error("Repository identity mismatch or unavailable repository");
        return repo;
    };
    action("getRepository", {
        async invoke({ kind, id, maxChars = 4000 }) {
            const url = repositoryUrl(kind, id);
            const document = await fetchPage(url);
            const repo = repositoryHeader(document, kind, id);
            const card = document.querySelector(kind === "model" ? ".model-card-content" : ".prose.hf-sanitized.copiable-code-container")?.textContent?.replace(/\s+/g, " ").trim() || null;
            const license = typeof repo.cardData?.license === "string" ? repo.cardData.license : (repo.tags ?? []).find(tag => tag.startsWith("license:"))?.slice(8) ?? null;
            return { kind, id, url, gated: repo.gated == null ? null : !!repo.gated, private: repo.private ?? null, task: repo.pipeline_tag ?? null,
                license, tags: (repo.tags ?? []).slice(0,100), updatedAt: repo.lastModified ?? null, card: card?.slice(0,maxChars) ?? null, cardTruncated: (card?.length ?? 0) > maxChars };
        },
    });
    action("listRepositoryFiles", {
        async invoke({ kind, id, revision = "main", path = "", limit = 100, cursor }) {
            const root = repositoryUrl(kind, id);
            if (path.split("/").some(part => part === "." || part === "..") || path.startsWith("/")) throw new Error("Invalid repository path");
            const document = await fetchPage(root);
            const repo = repositoryHeader(document, kind, id);
            if (repo.gated || repo.private) throw new Error("GATED_OR_PRIVATE_REPOSITORY: no access conditions accepted");
            const treeUrl = root + "/tree/" + encodeURIComponent(revision) + (path ? "/" + path.split("/").map(encodeURIComponent).join("/") : "");
            let entries, nextCursor = null, sourceUrl = treeUrl;
            const prefix = "/api/" + (kind === "model" ? "models/" : "datasets/") + id + "/tree/" + encodeURIComponent(revision) + (path ? "/" + path.split("/").map(encodeURIComponent).join("/") : "");
            if (cursor) {
                const next = new URL(cursor, ORIGIN);
                if (next.origin !== ORIGIN || next.pathname !== prefix || !next.searchParams.has("cursor") || !Number.isInteger(Number(next.searchParams.get("limit"))) || Number(next.searchParams.get("limit")) < 1 || Number(next.searchParams.get("limit")) > 100) throw new Error("Invalid or unbounded repository continuation");
                sourceUrl = next.href;
                const response = await retryFetch(sourceUrl, { credentials: "omit" });
                if (!response.ok) throw new Error("Repository tree HTTP " + response.status);
                entries = await response.json();
                const link = response.headers.get("link")?.match(/<([^>]+)>;\s*rel="next"/);
                nextCursor = link?.[1] ?? null;
            } else {
                const tree = component(await fetchPage(treeUrl), "ViewerIndexTreeList");
                if (tree.context?.repo?.name !== id || tree.context?.rev !== revision) throw new Error("Repository tree identity mismatch");
                entries = tree.entries;
                nextCursor = tree.nextURL ?? null;
            }
            if (!Array.isArray(entries) || entries.length > 100) throw new Error("Repository tree returned an unexpected or oversized page");
            const omittedFromPage = Math.max(0, entries.length - limit);
            const more = !!nextCursor;
            if (omittedFromPage) nextCursor = null;
            return { items: entries.slice(0,limit).map(entry => ({ path: entry.path, type: entry.type, size: Number.isInteger(entry.size) ? entry.size : null,
                oid: entry.oid ?? null, commitId: entry.lastCommit?.id ?? null, updatedAt: entry.lastCommit?.date ?? null })), nextCursor, sourceUrl,
                sourcePageCount: entries.length, omittedFromPage, complete: !more && !omittedFromPage, truncated: more || omittedFromPage > 0 };
        },
    });
    action("getDatasetPreview", {
        async invoke({ id, limit = 10, config, split }) {
            const url = repositoryUrl("dataset", id);
            const document = await fetchPage(url);
            const repo = repositoryHeader(document, "dataset", id);
            if (repo.gated || repo.private) throw new Error("GATED_OR_PRIVATE_DATASET: no access conditions accepted");
            const viewer = component(document, "DatasetViewer");
            if (viewer.isGated || viewer.isPrivate) throw new Error("GATED_OR_PRIVATE_DATASET");
            const data = viewer.data;
            const selectedConfig = data?.configsData?.selectedConfig;
            const selectedSplit = data?.splitsData?.selectedSplit;
            if (config && config !== selectedConfig || split && split !== selectedSplit) throw new Error("UNAVAILABLE_PREVIEW_SELECTION: only the observed initial config/split sample is supported");
            const sample = data?.sampleData?.sampleData;
            if (!Array.isArray(sample?.rows) || !Array.isArray(sample?.columns)) throw new Error("DATASET_PREVIEW_UNAVAILABLE: no public initial row sample");
            if (sample.columns.length > 100) throw new Error("Dataset sample exceeds 100 column limit");
            const configs = (data.configsData.configInfos ?? []).slice(0,100).map(item => ({ name: item.name, status: item.status ?? null, totalRows: item.numRows ?? null }));
            const splits = (data.splitsData.splitInfos ?? []).slice(0,100).map(item => ({ name: item.name, totalRows: item.numRows ?? null }));
            const totalRows = splits.find(item => item.name === selectedSplit)?.totalRows ?? null;
            let remainingText = 32000;
            const rows = sample.rows.slice(0,limit).map(row => ({ index: row.rowIdx, cells: sample.columns.map(column => {
                const cell = row.cells?.[column.name];
                const raw = cell?.value;
                const value = raw == null ? null : typeof raw === "string" || typeof raw === "number" || typeof raw === "boolean" ? String(raw) : null;
                const text = value?.slice(0, Math.min(1000, remainingText)) ?? null;
                remainingText -= text?.length ?? 0;
                return { column: column.name, kind: cell?.kind ?? column.type, value: text, truncated: (value?.length ?? 0) > (text?.length ?? 0) || raw != null && value === null };
            }) }));
            const complete = remainingText > 0 && !data.partial && !sample.truncated && totalRows !== null && rows.length === totalRows && !rows.some(row => row.cells.some(cell => cell.truncated));
            return { id, url, config: selectedConfig, split: selectedSplit, configs, splits, totalRows, availableSampleRows: sample.rows.length,
                columns: sample.columns.map(column => ({ name: column.name, type: column.type })), rows, complete, truncated: !complete, previewOnly: true };
        },
    });
    action("listSpaces", {
        async invoke({ category }) {
            const query = new URLSearchParams({
                category,
                includeNonRunning: "true",
            });
            const spaces = await fetchJson(`/api/spaces/semantic-search?${query}`);
            console.log(`listSpaces: ${spaces.length} spaces in ${category}`);
            return {
                items: spaces.map((space) => ({
                    id: space.id,
                    title: space.title || space.id,
                    author: space.author ?? null,
                    description: space.ai_short_description ?? space.shortDescription ?? null,
                    category: space.ai_category ?? null,
                    sdk: space.sdk ?? null,
                    likes: space.likes ?? 0,
                    running: space.runtime?.stage === "RUNNING",
                    updatedAt: space.lastModified ?? null,
                    url: `${ORIGIN}/spaces/${space.id}`,
                })),
                nextCursor: null,
            };
        },
    });
});
