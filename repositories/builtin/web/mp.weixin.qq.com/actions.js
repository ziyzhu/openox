const ARTICLE_PATH = /^\/s\/[A-Za-z0-9_-]+$/;
const IMAGE_HOST = "mmbiz.qpic.cn";
const BLOCK_TAGS = new Set([
    "address", "article", "aside", "blockquote", "div", "figcaption", "figure", "footer",
    "h1", "h2", "h3", "h4", "h5", "h6", "header", "li", "main", "ol", "p", "pre",
    "section", "table", "tbody", "td", "th", "thead", "tr", "ul",
]);
const SKIPPED_TAGS = new Set(["button", "canvas", "noscript", "script", "style", "svg"]);
const articleUrl = (value) => {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.hostname !== "mp.weixin.qq.com" || !ARTICLE_PATH.test(url.pathname)) {
        throw new Error("getArticle requires a shared https://mp.weixin.qq.com/s/ article URL");
    }
    url.hash = "";
    return url;
};
const imageUrl = (element) => {
    const raw = element?.getAttribute("data-src")
        || element?.getAttribute("src")
        || element?.getAttribute("content")
        || "";
    if (!raw)
        return null;
    try {
        const url = new URL(raw, "https://mp.weixin.qq.com/");
        if (url.hostname !== IMAGE_HOST)
            return null;
        url.protocol = "https:";
        return url.href;
    }
    catch {
        return null;
    }
};
const positiveInteger = (...values) => {
    for (const value of values) {
        const number = Number.parseFloat(value ?? "");
        if (Number.isFinite(number) && number > 0)
            return Math.round(number);
    }
    return null;
};
const articleText = (root, indexes) => {
    const render = (node) => {
        if (node.nodeType === 3)
            return node.textContent ?? "";
        if (node.nodeType !== 1)
            return "";
        const element = node;
        const tag = element.tagName.toLowerCase();
        if (SKIPPED_TAGS.has(tag))
            return "";
        if (tag === "img") {
            const index = indexes.get(element);
            return index ? `\n\n[Image ${index}]\n\n` : "";
        }
        if (tag === "br")
            return "\n";
        const content = [...element.childNodes].map(render).join("");
        if (tag === "li")
            return `\n- ${content}\n`;
        return BLOCK_TAGS.has(tag) ? `\n${content}\n` : content;
    };
    return render(root)
        .replace(/\u00a0/g, " ")
        .replace(/[ \t]+/g, " ")
        .replace(/ *\n */g, "\n")
        .replace(/\n{3,}/g, "\n\n")
        .trim();
};
window.ox.install(1, ({ action, retryFetch, lib }) => {
    const { cleanText } = lib;
    action("getArticle", {
        async invoke({ url: inputUrl }) {
            const requestedUrl = articleUrl(inputUrl);
            const response = await retryFetch(requestedUrl.href, { credentials: "include" });
            if (!response.ok)
                throw new Error(`getArticle: HTTP ${response.status}`);
            const document = new DOMParser().parseFromString(await response.text(), "text/html");
            const contentElement = document.querySelector("#js_content");
            const title = cleanText(document.querySelector("#activity-name")?.textContent
                || document.querySelector('meta[property="og:title"]')?.content);
            if (!contentElement || !title) {
                throw new Error("getArticle: article content is unavailable or requires verification");
            }
            const indexes = new Map();
            const images = [...contentElement.querySelectorAll("img")].flatMap((element) => {
                const source = imageUrl(element);
                if (!source)
                    return [];
                const index = indexes.size + 1;
                indexes.set(element, index);
                return [{
                        index,
                        url: source,
                        alt: cleanText(element.getAttribute("alt")) || null,
                        width: positiveInteger(element.getAttribute("data-width"), element.getAttribute("data-w"), element.getAttribute("width")),
                        height: positiveInteger(element.getAttribute("data-height"), element.getAttribute("data-h"), element.getAttribute("height")),
                    }];
            });
            const coverImageUrl = imageUrl(document.querySelector('meta[property="og:image"]'));
            return {
                title,
                accountName: cleanText(document.querySelector("#js_name")?.textContent),
                publishedAt: cleanText(document.querySelector("#publish_time")?.textContent),
                summary: cleanText(document.querySelector('meta[property="og:description"]')?.content),
                url: requestedUrl.href,
                coverImageUrl,
                content: articleText(contentElement, indexes),
                images,
            };
        },
    });
});
