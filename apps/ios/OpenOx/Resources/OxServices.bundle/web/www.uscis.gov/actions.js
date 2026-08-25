const ORIGIN = "https://www.uscis.gov";
window.ox.install(1, ({ action, retryFetch, log, lib }) => {
    const { pageCursor } = lib;
    const absUrl = (p) => {
        if (!p)
            return "";
        if (/^https?:\/\//.test(p))
            return p;
        return ORIGIN + (p.startsWith("/") ? p : `/${p}`);
    };
    action("getPage", {
        async invoke({ path } = {}) {
            if (!path)
                throw new Error("path is required");
            const url = absUrl(path);
            if (!url.startsWith(ORIGIN))
                throw new Error("path must be on www.uscis.gov");
            const html = await (await retryFetch(url, { credentials: "include" })).text();
            const doc = new DOMParser().parseFromString(html, "text/html");
            const title = (doc.querySelector("h1")?.textContent || doc.title || "").trim();
            const main = doc.querySelector("main#main") ||
                doc.querySelector(".main-content-wrapper") ||
                doc.querySelector("main") ||
                doc.body;
            main
                .querySelectorAll("script,style,noscript,nav,header,footer,form,iframe,.usa-banner,.skip-links")
                .forEach((e) => e.remove());
            const text = (main.textContent || "")
                .replace(/[ \t]+/g, " ")
                .replace(/\n[ \t]+/g, "\n")
                .replace(/\n{3,}/g, "\n\n")
                .trim();
            const seen = new Set();
            const links = [...main.querySelectorAll("a[href]")]
                .map((a) => ({
                text: (a.textContent || "").trim(),
                url: absUrl(a.getAttribute("href") || ""),
            }))
                .filter((l) => l.text && /^https?:\/\//.test(l.url) && !seen.has(l.url) && seen.add(l.url))
                .slice(0, 80);
            return { url, title, text: text.slice(0, 20000), links };
        },
    });
    const renderSearch = async (query) => {
        const iframe = document.createElement("iframe");
        iframe.style.cssText =
            "position:absolute;left:-99999px;top:0;width:1024px;height:3000px;visibility:hidden;";
        const loaded = new Promise((res) => {
            iframe.onload = () => res();
        });
        document.body.appendChild(iframe);
        iframe.src = `${ORIGIN}/search?query=${encodeURIComponent(query)}`;
        await loaded;
        let doc = iframe.contentDocument;
        const ready = () => doc && doc.querySelector(".gsc-webResult.gsc-result, .gs-no-results-result, .gsc-results");
        for (let i = 0; i < 60 && !ready(); i++) {
            await new Promise((r) => setTimeout(r, 200));
            doc = iframe.contentDocument;
        }
        return { iframe, doc };
    };
    action("searchSite", {
        async invoke({ query } = {}) {
            let iframe;
            try {
                if (!query)
                    throw new Error("query is required");
                const r = await renderSearch(query);
                iframe = r.iframe;
                const doc = r.doc;
                if (!doc)
                    throw new Error("search did not render");
                const items = [...doc.querySelectorAll(".gsc-webResult.gsc-result")]
                    .map((el) => {
                    const a = el.querySelector("a.gs-title");
                    const url = a?.getAttribute("data-ctorig") || a?.getAttribute("href") || "";
                    const title = (a?.textContent || "").replace(/\s+/g, " ").trim();
                    const snippet = (el.querySelector(".gs-snippet")?.textContent || "")
                        .replace(/\s+/g, " ")
                        .trim();
                    return { title, url, snippet };
                })
                    .filter((x) => x.title && /^https?:\/\//.test(x.url));
                log(`uscis search "${query}" -> ${items.length} results`);
                return { items, nextCursor: null };
            }
            finally {
                iframe?.remove();
            }
        },
    });
    const clean = (s) => (s || "").replace(/\s+/g, " ").trim();
    action("listNews", {
        async invoke({ cursor } = {}) {
            const page = pageCursor(cursor, 0);
            const url = `${ORIGIN}/newsroom/all-news?page=${page}`;
            const html = await (await retryFetch(url, { credentials: "include" })).text();
            const doc = new DOMParser().parseFromString(html, "text/html");
            const items = [...doc.querySelectorAll(".views-row")]
                .map((row) => {
                const a = row.querySelector(".views-field-title a");
                return {
                    title: clean(a?.textContent),
                    url: absUrl(a?.getAttribute("href") || ""),
                    date: clean(row.querySelector(".views-field-field-display-date")?.textContent),
                    summary: clean(row.querySelector(".views-field-body")?.textContent),
                };
            })
                .filter((x) => x.title && x.url);
            const hasNext = !!doc.querySelector(".pager__item--next a, a[rel='next']");
            return { items, nextCursor: hasNext ? String(page + 1) : null };
        },
    });
    action("getForm", {
        async invoke({ form } = {}) {
            if (!form)
                throw new Error("form is required");
            const slug = form.toLowerCase().replace(/[^a-z0-9-]/g, "");
            const url = `${ORIGIN}/${slug}`;
            const html = await (await retryFetch(url, { credentials: "include" })).text();
            const doc = new DOMParser().parseFromString(html, "text/html");
            const title = clean(doc.querySelector("h1")?.textContent || doc.title);
            const scope = doc.querySelector(".field--name-field-attached-files") ||
                doc.querySelector("main#main") ||
                doc.body;
            const seen = new Set();
            const files = [...scope.querySelectorAll("a[href$='.pdf']")]
                .map((a) => {
                const info = a.closest(".media--type-document, .file")?.querySelector(".file-ext-info, .extra-info") ||
                    null;
                return {
                    label: clean(a.textContent),
                    url: absUrl(a.getAttribute("href") || ""),
                    info: clean(info?.textContent),
                };
            })
                .filter((f) => f.url && !seen.has(f.url) && seen.add(f.url));
            if (files.length === 0)
                throw new Error(`no downloadable PDF found for ${form} at ${url}`);
            return { form, title, url, files };
        },
    });
});
