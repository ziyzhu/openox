import type { ActionInstaller } from "@openox/service-sdk/action";
import { pageCursor } from "@openox/service-sdk/action-lib";

const install: ActionInstaller = ({ action, retryFetch, log }) => {
  const ORIGIN = "https://huggingface.co";

  const fetchJson = async (path: string) => {
    const response = await retryFetch(`${ORIGIN}${path}`, {
      credentials: "include",
      headers: { Accept: "application/json" },
    });
    if (!response.ok) throw new Error(`GET ${path} -> ${response.status}`);
    return response.json();
  };

  const nextPage = (page: number, pageSize: number, total: number) =>
    page * pageSize < total ? String(page + 1) : null;

  action("listModels", {
    async invoke({ library, cursor }: { library?: string; cursor?: string }) {
      const page = pageCursor(cursor, 1);
      const query = new URLSearchParams({
        p: String(page),
        sort: "trending",
        withCount: "true",
      });
      if (library) query.set("library", library);
      const data = await fetchJson(`/models-json?${query}`);
      const models: any[] = data.models ?? [];
      log(`listModels: page ${page}, ${models.length} models`);
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
        nextCursor: nextPage(
          data.pageIndex ?? page,
          data.numItemsPerPage ?? models.length,
          data.numTotalItems ?? models.length,
        ),
      };
    },
  });

  action("listDatasets", {
    async invoke({ cursor }: { cursor?: string }) {
      const page = pageCursor(cursor, 1);
      const query = new URLSearchParams({
        p: String(page),
        sort: "trending",
        withCount: "true",
      });
      const data = await fetchJson(`/datasets-json?${query}`);
      const datasets: any[] = data.datasets ?? [];
      log(`listDatasets: page ${page}, ${datasets.length} datasets`);
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
        nextCursor: nextPage(
          data.pageIndex ?? page,
          data.numItemsPerPage ?? datasets.length,
          data.numTotalItems ?? datasets.length,
        ),
      };
    },
  });

  action("listSpaces", {
    async invoke({ category }: { category: string }) {
      const query = new URLSearchParams({
        category,
        includeNonRunning: "true",
      });
      const spaces: any[] = await fetchJson(`/api/spaces/semantic-search?${query}`);
      log(`listSpaces: ${spaces.length} spaces in ${category}`);
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
};

export default install;
