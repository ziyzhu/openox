const ORIGIN = "https://archive.ph";
const CAPTURE_ID = /^[A-Za-z0-9]{5}$/;
window.ox.install(1, ({ action, retryFetch }) => {
    const documentFrom = async (response, context) => {
        if (!response.ok)
            throw new Error(`${context}: HTTP ${response.status}`);
        return new DOMParser().parseFromString(await response.text(), "text/html");
    };
    const fetchDocument = async (url, context) => {
        const response = await retryFetch(url, { credentials: "include" });
        return documentFrom(response, context);
    };
    const normalizedUrl = (value) => {
        try {
            return new URL(value).href;
        }
        catch {
            return value;
        }
    };
    const captureIdFromUrl = (value) => {
        const pathname = new URL(value, ORIGIN).pathname;
        const id = pathname.split("/").filter(Boolean)[0] ?? "";
        return CAPTURE_ID.test(id) ? id : "";
    };
    const originalUrlFromDocument = (document) => {
        const canonical = document.querySelector('link[rel="canonical"]')?.href ?? "";
        const match = canonical.match(/\/\d{4}\.\d{2}\.\d{2}-\d{6}\/(https?:\/\/.*)$/);
        return match?.[1] ?? "";
    };
    const captureFromDocument = (document, fallbackId = "") => {
        const archiveUrl = document.querySelector('meta[property="og:url"]')?.content ?? "";
        const id = captureIdFromUrl(archiveUrl) || fallbackId;
        const originalUrl = originalUrlFromDocument(document);
        if (!id || !originalUrl)
            throw new Error("Archive.ph capture page is missing its capture identity");
        return {
            id,
            title: document.querySelector('meta[property="og:title"]')?.content
                ?? document.title
                ?? "",
            originalUrl,
            archiveUrl: archiveUrl || `${ORIGIN}/${id}`,
            capturedAt: document.querySelector('meta[property="article:published_time"]')?.content ?? "",
            screenshotUrl: document.querySelector('meta[property="og:image"]')?.content ?? "",
        };
    };
    const lookupUrl = (query) => `${ORIGIN}/${query.replaceAll("#", "%23")}`;
    const submitUrl = (url) => `${ORIGIN}/submit/?url=${encodeURIComponent(url)}`;
    action("searchCaptures", {
        async invoke({ query, limit = 20 }) {
            const document = await fetchDocument(lookupUrl(query), "searchCaptures");
            const items = [...document.querySelectorAll('[id^="row"]')]
                .flatMap((row) => {
                const originalUrl = [...row.querySelectorAll(".TEXT-BLOCK a")]
                    .map((link) => link.innerText.trim())
                    .find((value) => /^https?:\/\//.test(value)) ?? "";
                return [...row.querySelectorAll(".THUMBS-BLOCK a")]
                    .map((link) => {
                    const id = captureIdFromUrl(link.href);
                    const image = link.querySelector("img");
                    if (!id || !image || !originalUrl)
                        return null;
                    return {
                        id,
                        title: image.title || image.alt.replace(/^screenshot of\s+/i, ""),
                        originalUrl,
                        archiveUrl: `${ORIGIN}/${id}`,
                        capturedAt: link.querySelector("div")?.textContent?.trim() ?? "",
                        thumbnailUrl: new URL(image.getAttribute("src") ?? "", ORIGIN).href,
                    };
                })
                    .filter((item) => item !== null);
            })
                .slice(0, limit);
            return { items, nextCursor: null };
        },
    });
    action("getCapture", {
        async invoke({ id }) {
            if (!CAPTURE_ID.test(id))
                throw new Error(`getCapture: invalid capture id ${id}`);
            const document = await fetchDocument(`${ORIGIN}/${id}`, "getCapture");
            return captureFromDocument(document, id);
        },
    });
    action("createCapture", {
        async invoke({ url }) {
            const response = await fetch(submitUrl(url), { credentials: "include" });
            if (response.status === 429) {
                throw new Error("BOT_CONTROL_REQUIRED: Archive.ph needs human verification. Use request_bot_control with the same url, then continue from the completed capture.");
            }
            const document = await documentFrom(response, "createCapture");
            const capture = captureFromDocument(document);
            if (normalizedUrl(capture.originalUrl) !== normalizedUrl(url)) {
                throw new Error("createCapture: Archive.ph returned a capture for a different URL");
            }
            return capture;
        },
    });
    action("getBotControlUrl", {
        async invoke({ url }) {
            return { url: submitUrl(url) };
        },
    });
    action("getBotControlState", {
        async invoke({ url, pageUrl }) {
            const page = new URL(pageUrl);
            if (page.origin !== ORIGIN)
                return { ok: false };
            const id = captureIdFromUrl(page.href);
            if (!id)
                return { ok: false };
            const document = await fetchDocument(`${ORIGIN}/${id}`, "getBotControlState");
            return { ok: normalizedUrl(originalUrlFromDocument(document)) === normalizedUrl(url) };
        },
    });
});
