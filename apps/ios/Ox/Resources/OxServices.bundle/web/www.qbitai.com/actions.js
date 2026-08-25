window.ox.install(1, ({ action, retryFetch, lib }) => {
    const { pageCursor } = lib;
    const API = "https://www.qbitai.com/wp-json/wp/v2";
    const htmlToText = (html) => {
        const doc = new DOMParser().parseFromString(html ?? "", "text/html");
        return (doc.body?.textContent ?? "").replace(/\s+/g, " ").trim();
    };
    const getJson = async (path) => {
        const res = await retryFetch(`${API}${path}`, { credentials: "include" });
        if (!res.ok)
            throw new Error(`HTTP ${res.status} for ${path}`);
        return { body: await res.json(), totalPages: parseInt(res.headers.get("X-WP-TotalPages") ?? "0", 10) || 0 };
    };
    const summaryOf = (p) => {
        const media = p?._embedded?.["wp:featuredmedia"]?.[0];
        return {
            id: String(p.id),
            title: htmlToText(p?.title?.rendered ?? ""),
            excerpt: htmlToText(p?.excerpt?.rendered ?? ""),
            url: p?.link ?? "",
            date: p?.date ?? "",
            author: p?._embedded?.author?.[0]?.name ?? "",
            image: media?.source_url ?? null,
        };
    };
    const articleOf = (p) => {
        const terms = (p?._embedded?.["wp:term"] ?? []).flat();
        return {
            ...summaryOf(p),
            content: htmlToText(p?.content?.rendered ?? ""),
            tags: terms.map((t) => t?.name).filter(Boolean),
        };
    };
    const listPage = async (path, limit, cursor) => {
        const page = pageCursor(cursor, 1);
        const lim = Math.min(Math.max(limit, 1), 50);
        const { body, totalPages } = await getJson(`${path}per_page=${lim}&page=${page}&_embed=1`);
        const items = (Array.isArray(body) ? body : []).map(summaryOf);
        const nextCursor = page < totalPages && items.length === lim ? String(page + 1) : null;
        return { items, nextCursor };
    };
    action("listPosts", {
        async invoke({ limit = 20, cursor } = {}) {
            return await listPage("/posts?", limit, cursor);
        },
    });
    action("searchPosts", {
        async invoke({ query, limit = 20, cursor }) {
            if (!query)
                throw new Error("searchPosts: query is required");
            return await listPage(`/posts?search=${encodeURIComponent(query)}&`, limit, cursor);
        },
    });
    action("getPost", {
        async invoke({ id }) {
            const { body } = await getJson(`/posts/${encodeURIComponent(id)}?_embed=1`);
            if (!body?.id)
                throw new Error(`getPost: no article for id ${id}`);
            return articleOf(body);
        },
    });
});
