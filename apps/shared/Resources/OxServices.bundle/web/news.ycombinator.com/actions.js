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
    const fetchDoc = async (path) => {
        const html = await (await retryFetch(path, { credentials: "include" })).text();
        return new DOMParser().parseFromString(html, "text/html");
    };
    const FEED_PATHS = {
        top: "/news",
        new: "/newest",
        best: "/best",
        ask: "/ask",
        show: "/show",
        jobs: "/jobs",
        front: "/front",
    };
    const parseRow = (row) => {
        const id = row.id;
        const titleEl = row.querySelector(".titleline a");
        const sitebit = row.querySelector(".sitestr");
        const sub = row.nextElementSibling?.querySelector(".subtext");
        const score = parseInt(sub?.querySelector(".score")?.innerText ?? "0", 10) || 0;
        const author = sub?.querySelector(".hnuser")?.innerText ?? "";
        const age = sub?.querySelector(".age")?.innerText ?? "";
        const links = [...(sub?.querySelectorAll("a") ?? [])];
        const cmtsEl = links.find((a) => /comment|discuss/i.test(a.innerText));
        const comments = parseInt((cmtsEl?.innerText ?? "").replace(/\D/g, ""), 10) || 0;
        const hidden = !!links.find((a) => /^un-?hide$/i.test(a.innerText));
        const url = titleEl?.href ?? "";
        const domain = sitebit?.innerText ?? "";
        const externalUrl = url && domain ? url : null;
        return {
            id,
            title: titleEl?.innerText ?? "",
            url,
            externalUrl,
            domain,
            score, author, age, comments, hidden,
        };
    };
    const parseComments = (root) => {
        return [...root.querySelectorAll("tr.athing.comtr")].map((row) => {
            const id = row.id;
            const indentTd = row.querySelector("td.ind");
            const indentAttr = indentTd?.getAttribute("indent");
            const imgWidth = indentTd?.querySelector("img")?.getAttribute("width");
            const level = indentAttr != null
                ? parseInt(indentAttr, 10) || 0
                : Math.round((parseInt(imgWidth || "0", 10) || 0) / 40);
            const author = row.querySelector(".hnuser")?.innerText ?? "";
            const age = row.querySelector(".age")?.innerText ?? "";
            const text = row.querySelector(".commtext")?.innerText ?? "";
            return { id, author, level, age, text, parentId: null };
        }).map((c, i, arr) => {
            if (c.level === 0)
                return c;
            for (let j = i - 1; j >= 0; j--) {
                if (arr[j].level === c.level - 1) {
                    c.parentId = arr[j].id;
                    break;
                }
            }
            return c;
        });
    };
    const probeSignedIn = async () => {
        const doc = await fetchDoc("/news");
        return !!doc.querySelector("#me");
    };
    const storyFromRow = (row) => {
        const r = parseRow(row);
        return {
            id: r.id, title: r.title, url: r.url, externalUrl: r.externalUrl,
            domain: r.domain, score: r.score, author: r.author, age: r.age,
            comments: r.comments, hidden: false,
        };
    };
    action("getSignInUrl", {
        async invoke() {
            return { url: "https://news.ycombinator.com/login" };
        },
    });
    action("getSignInState", {
        async invoke() {
            return { signedIn: await probeSignedIn() };
        },
    });
    action("getCurrentUser", {
        async invoke() {
            const doc = await fetchDoc("/news");
            const me = doc.querySelector("#me");
            const karmaEl = doc.querySelector("#karma");
            const user = me?.innerText?.trim();
            if (!user)
                throw new Error("getCurrentUser: requires sign-in");
            const karma = karmaEl ? parseInt(karmaEl.innerText, 10) : NaN;
            if (!Number.isFinite(karma))
                throw new Error("getCurrentUser: missing karma");
            return { user, karma };
        },
    });
    action("listStories", {
        async invoke({ feed = "top", limit = 30, cursor } = {}) {
            const path = FEED_PATHS[feed] ?? FEED_PATHS.top;
            const page = pageCursor(cursor, 1);
            const doc = await fetchDoc(`${path}${page > 1 ? `?p=${page}` : ""}`);
            const items = [...doc.querySelectorAll("tr.athing")].slice(0, limit).map(parseRow);
            const nextCursor = items.length === limit ? String(page + 1) : null;
            return { items, nextCursor };
        },
    });
    action("getStory", {
        async invoke({ id }) {
            const doc = await fetchDoc(`/item?id=${encodeURIComponent(id)}`);
            const row = doc.querySelector("tr.athing");
            if (!row)
                throw new Error(`getStory: no story found for id ${id}`);
            return storyFromRow(row);
        },
    });
    action("getPost", {
        async invoke({ id }) {
            const doc = await fetchDoc(`/item?id=${encodeURIComponent(id)}`);
            const row = doc.querySelector("tr.athing.submission") || doc.querySelector("tr.athing");
            if (!row)
                throw new Error(`getPost: no post found for id ${id}`);
            const story = parseRow(row);
            const comments = parseComments(doc);
            return { story, comments };
        },
    });
    action("createComment", {
        async invoke({ parentId, text }) {
            const doc = await fetchDoc("reply?id=" + parentId);
            const form = doc.querySelector("form[action='comment']");
            if (!form)
                return { ok: false };
            const body = new URLSearchParams();
            for (const input of form.querySelectorAll("input[type=hidden]")) {
                body.set(input.name, input.value);
            }
            body.set("text", text);
            const res = await fetch("comment", { method: "POST", credentials: "include", body });
            return { ok: res.ok };
        },
    });
    action("search", {
        async invoke({ query, type = "story", author, order = "relevance", startDate, endDate, limit = 20, cursor }) {
            const day = value => {
                const time = Date.parse(value + "T00:00:00Z");
                if (!Number.isFinite(time) || new Date(time).toISOString().slice(0, 10) !== value) throw new Error("Invalid UTC date");
                return time / 1000;
            };
            const start = startDate ? day(startDate) : null;
            const end = endDate ? day(endDate) + 86400 : null;
            if (start !== null && end !== null && start >= end) throw new Error("startDate must not exceed endDate");
            const page = Number(cursor ?? 0);
            if (!Number.isSafeInteger(page) || page < 0) throw new Error("Invalid source page");
            const params = new URLSearchParams({ query, tags: type + (author ? ",author_" + author : ""), hitsPerPage: String(limit), page: String(page) });
            const filters = [];
            if (start !== null) filters.push("created_at_i>=" + start);
            if (end !== null) filters.push("created_at_i<" + end);
            if (filters.length) params.set("numericFilters", filters.join(","));
            const url = "https://hn.algolia.com/api/v1/" + (order === "date" ? "search_by_date" : "search") + "?" + params;
            const response = await retryFetch(url, { credentials: "omit" });
            if (!response.ok) throw new Error("HN search HTTP " + response.status);
            const data = await response.json();
            if (!Array.isArray(data.hits) || !Number.isInteger(data.page) || !Number.isInteger(data.nbPages)) throw new Error("HN search returned an unexpected response");
            const text = html => html == null ? null : new DOMParser().parseFromString(String(html), "text/html").body.textContent;
            const items = data.hits.map(hit => {
                const body = text(type === "comment" ? hit.comment_text : hit.story_text);
                return { id: String(hit.objectID), type, title: hit.title ?? null, text: body?.slice(0, 4000) ?? null,
                    author: hit.author ?? null, createdAt: hit.created_at ?? null, url: "https://news.ycombinator.com/item?id=" + hit.objectID,
                    externalUrl: hit.url ?? null, storyId: hit.story_id == null ? null : String(hit.story_id), storyTitle: hit.story_title ?? null,
                    points: hit.points ?? null, comments: hit.num_comments ?? null, textTruncated: (body?.length ?? 0) > 4000 };
            });
            const nextCursor = data.page + 1 < data.nbPages ? String(data.page + 1) : null;
            const totalHitsExact = data.exhaustiveNbHits === true;
            const complete = data.page === 0 && data.nbHits === items.length && totalHitsExact && !items.some(item => item.textTruncated);
            return { items, nextCursor, totalHits: data.nbHits, totalHitsExact, sourcePages: data.nbPages, page: data.page, complete, truncated: nextCursor !== null || !complete, sourceUrl: url };
        },
    });
    action("getUser", {
        async invoke({ username }) {
            const doc = await fetchDoc(`/user?id=${encodeURIComponent(username)}`);
            const findRow = (label) => {
                for (const tr of doc.querySelectorAll("tr")) {
                    const td = tr.querySelector("td");
                    if (td && td.innerText.trim().toLowerCase() === label) {
                        return tr.querySelectorAll("td")[1];
                    }
                }
                return null;
            };
            const userText = findRow("user:")?.innerText.trim() || username;
            const karmaText = findRow("karma:")?.innerText.trim() || "";
            const karma = parseInt(karmaText, 10);
            if (!Number.isFinite(karma))
                throw new Error(`getUser: no profile for ${username}`);
            const createdText = findRow("created:")?.innerText.trim() || "";
            const aboutEl = findRow("about:");
            return {
                username: userText,
                karma,
                created: createdText,
                about: aboutEl ? aboutEl.innerHTML.trim() : "",
            };
        },
    });
});
