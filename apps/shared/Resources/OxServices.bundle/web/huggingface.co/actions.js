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
    const nextPage = (page, pageSize, total) => page * pageSize < total ? String(page + 1) : null;
    action("listModels", {
        async invoke({ library, cursor }) {
            const page = pageCursor(cursor, 1);
            const query = new URLSearchParams({
                p: String(page),
                sort: "trending",
                withCount: "true",
            });
            if (library)
                query.set("library", library);
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
        async invoke({ cursor }) {
            const page = pageCursor(cursor, 1);
            const query = new URLSearchParams({
                p: String(page),
                sort: "trending",
                withCount: "true",
            });
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
