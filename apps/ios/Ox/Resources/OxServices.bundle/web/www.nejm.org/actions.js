const ORIGIN = "https://www.nejm.org";
const START_URL = `${ORIGIN}/action/autoCompleteSearchService?partialQuery=zzzzunlikelyqueryzzzz`;
const inputValue = (element, selector) => element.querySelector(selector)?.value?.trim() ?? "";
const absoluteUrl = (value) => value ? new URL(value, ORIGIN).href : "";
const readableText = (element) => {
    if (!element)
        return "";
    const copy = element.cloneNode(true);
    copy.querySelectorAll("script, style, button, svg, .external-links").forEach((node) => node.remove());
    copy.querySelectorAll("br, p, li, tr, h1, h2, h3, h4, [role='paragraph']")
        .forEach((node) => node.before(" "));
    return cleanText(copy.textContent);
};
const articleItems = (doc) => [...doc.querySelectorAll(".os-search-results_list-item .issue-item")]
    .map((element) => {
    const id = inputValue(element, ".inputDoi");
    const titleLink = element.querySelector(".issue-item_title-link");
    const title = inputValue(element, ".inputArticleTitle") || cleanText(titleLink?.textContent);
    const url = absoluteUrl(titleLink?.getAttribute("href") ?? null);
    const authors = inputValue(element, ".inputAuthor") || cleanText(element.querySelector(".issue-item_authors")?.textContent);
    const citation = inputValue(element, ".inputCitation") || cleanText(element.querySelector(".issue-item_authors-after")?.textContent);
    const publishedAt = inputValue(element, ".inputEPubDate") || cleanText(element.querySelector(".issue-item_date")?.textContent);
    const articleType = inputValue(element, ".inputContentType") || cleanText(element.querySelector(".issue-item_type")?.textContent);
    const snippet = readableText(element.querySelector(".issue-item_abstractText"));
    const pdfUrl = absoluteUrl(element.querySelector("a.issue-item_pdf")?.getAttribute("href") ?? null);
    return {
        id,
        title,
        url,
        ...(authors ? { authors } : {}),
        ...(citation ? { citation } : {}),
        ...(publishedAt ? { publishedAt } : {}),
        ...(articleType ? { articleType } : {}),
        ...(snippet ? { snippet } : {}),
        ...(pdfUrl ? { pdfUrl } : {}),
    };
})
    .filter((item) => item.id && item.title && item.url);
const totalCount = (doc) => {
    const value = doc.querySelector("input[name='total']")?.value ?? "";
    return Number.parseInt(value.replace(/\D/g, ""), 10) || 0;
};
const nextCursor = (doc) => doc.querySelector(".ng-pagination_next[aria-disabled='false']")?.dataset.startpage ?? null;
window.ox.install(1, ({ action, retryFetch, log, lib }) => {
    const { cleanText, pageCursor } = lib;
    const fetchDocument = async (url) => {
        const response = await retryFetch(url, { credentials: "include" });
        if (!response.ok)
            throw new Error(`NEJM HTTP ${response.status}`);
        const html = await response.text();
        return new DOMParser().parseFromString(html, "text/html");
    };
    const fetchResultsPage = async ({ firstUrl, page, searchType, subPageType, pbContext, query, }) => {
        const firstPage = await fetchDocument(firstUrl);
        if (page === 1)
            return { doc: firstPage, firstPage };
        const widgetId = firstPage.querySelector("input[name='widgetID']")?.value;
        if (!widgetId)
            throw new Error("NEJM results widget was not found");
        const params = new URLSearchParams({
            startPage: String(page),
            isFiltered: "true",
            pbContext,
            widgetId,
            searchType,
            subPageType,
        });
        if (query)
            params.set("q", query);
        const doc = await fetchDocument(`${ORIGIN}/pb/widgets/mmsSearchResults?${params}`);
        return { doc, firstPage };
    };
    action("searchArticles", {
        async invoke({ query, cursor }) {
            if (!query)
                throw new Error("searchArticles: query is required");
            const page = pageCursor(cursor, 1);
            const params = new URLSearchParams({ q: query });
            const { doc } = await fetchResultsPage({
                firstUrl: `${ORIGIN}/search?${params}`,
                page,
                searchType: "quickSearch",
                subPageType: "",
                pbContext: ";page:string:Search Result;wgroup:string:MMS NextGen Website Group;pageGroup:string:Search Flow;website:website:mms-site",
                query,
            });
            const items = articleItems(doc);
            const total = totalCount(doc);
            const next = nextCursor(doc);
            log(`searchArticles "${query}" page ${page}: ${items.length}/${total}`);
            return { items, totalCount: total, nextCursor: next };
        },
    });
    action("listSpecialtyArticles", {
        async invoke({ specialty, cursor }) {
            if (!specialty)
                throw new Error("listSpecialtyArticles: specialty is required");
            const page = pageCursor(cursor, 1);
            const firstUrl = `${ORIGIN}/browse/specialty/${encodeURIComponent(specialty)}`;
            const { doc, firstPage } = await fetchResultsPage({
                firstUrl,
                page,
                searchType: "browseSpecialty",
                subPageType: specialty,
                pbContext: `;subPage:string:Topic Landing Page;taxonomy:taxonomy:specialty;topic:topic:specialty>${specialty};page:string:Search Result;wgroup:string:MMS NextGen Website Group;pageGroup:string:Search Flow;website:website:mms-site`,
            });
            const name = cleanText(firstPage.querySelector(".ng-page_title-heading")?.textContent) || specialty;
            const items = articleItems(doc);
            const total = totalCount(doc);
            const next = nextCursor(doc);
            log(`listSpecialtyArticles ${specialty} page ${page}: ${items.length}/${total}`);
            return { name, items, totalCount: total, nextCursor: next };
        },
    });
    action("getArticle", {
        async invoke({ id }) {
            if (!id)
                throw new Error("getArticle: id is required");
            const doiPath = id.split("/").map(encodeURIComponent).join("/");
            const url = `${ORIGIN}/doi/full/${doiPath}`;
            const doc = await fetchDocument(url);
            const metadata = (name) => cleanText(doc.querySelector(`meta[name='${name}']`)?.content);
            const title = cleanText(doc.querySelector("h1[property='name']")?.textContent) || metadata("dc.Title");
            if (!title)
                throw new Error(`getArticle: no article found for ${id}`);
            const authors = [...doc.querySelectorAll("meta[name='dc.Creator']")]
                .map((element) => cleanText(element.content))
                .filter(Boolean);
            const description = metadata("dc.Description");
            const publishedAt = metadata("dc.Date");
            const articleType = metadata("dc.Type");
            const abstract = readableText(doc.querySelector("#summary-abstract"));
            const sections = [...doc.querySelectorAll("#bodymatter > .core-container > section")]
                .map((section) => ({
                title: cleanText(section.querySelector(":scope > h2")?.textContent),
                text: readableText(section),
            }))
                .filter((section) => section.title && section.text);
            const topics = [...doc.querySelectorAll("[property='keywords'] a")]
                .map((element) => cleanText(element.textContent))
                .filter(Boolean);
            const notices = [...doc.querySelectorAll(".core-relations .relation--head")]
                .map((element) => readableText(element))
                .filter(Boolean);
            const pdfUrl = absoluteUrl(doc.querySelector("a.btn--pdf")?.getAttribute("href") ?? null);
            log(`getArticle ${id}: ${authors.length} authors, ${sections.length} sections`);
            return {
                id,
                title,
                authors,
                topics,
                notices,
                sections,
                url,
                ...(description ? { description } : {}),
                ...(publishedAt ? { publishedAt } : {}),
                ...(articleType ? { articleType } : {}),
                ...(abstract ? { abstract } : {}),
                ...(pdfUrl ? { pdfUrl } : {}),
            };
        },
    });
});
