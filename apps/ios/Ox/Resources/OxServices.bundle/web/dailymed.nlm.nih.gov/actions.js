const ORIGIN = "https://dailymed.nlm.nih.gov";
const START_URL = `${ORIGIN}/dailymed/autocomplete.cfm?key=search&returntype=json&term=zzzzunlikelyqueryzzzz`;
const FIELD_PREFIXES = {
    name: "NAME",
    ndc: "NDC",
    applicationNumber: "APPLICATION_NUMBER",
    setId: "SETID",
    documentId: "DOCUMENT_ID",
    drugClass: "CLASS",
    activeMoiety: "ACTIVEMOIETY",
    activeIngredient: "INGREDIENT",
    inactiveIngredient: "INACTIVE_INGREDIENT",
};
const textList = (element) => {
    if (!element)
        return [];
    const copy = element.cloneNode(true);
    copy.querySelectorAll("a").forEach((node) => node.remove());
    return cleanText(copy.textContent)
        .split(",")
        .map((value) => cleanText(value))
        .filter(Boolean);
};
const absoluteUrl = (value) => value ? new URL(value, ORIGIN).href : "";
const readableText = (element) => {
    const copy = element.cloneNode(true);
    copy.querySelectorAll("br, p, li, tr, td, th, h1, h2, h3, h4").forEach((node) => node.before(" "));
    return cleanText(copy.textContent);
};
window.ox.install(1, ({ action, retryFetch, log, lib }) => {
    const { cleanText, pageCursor } = lib;
    const fetchDocument = async (url) => {
        const response = await retryFetch(url, { credentials: "omit" });
        if (!response.ok)
            throw new Error(`DailyMed HTTP ${response.status}`);
        const html = await response.text();
        return new DOMParser().parseFromString(html, "text/html");
    };
    action("searchDrugLabels", {
        async invoke({ query, field = "all", labelType = "all", cursor, limit = 20 }) {
            if (!query)
                throw new Error("searchDrugLabels: query is required");
            const page = pageCursor(cursor, 1);
            const pageSize = Math.min(200, Math.max(1, limit));
            const prefix = FIELD_PREFIXES[field];
            const searchQuery = prefix ? `${prefix}:(${query})` : query;
            const params = new URLSearchParams({
                labeltype: labelType,
                query: searchQuery,
                page: String(page),
                pagesize: String(pageSize),
            });
            if (prefix)
                params.set("adv", "1");
            const doc = await fetchDocument(`${ORIGIN}/dailymed/search.cfm?${params}`);
            const items = [...doc.querySelectorAll(".results article.row")].map((row) => {
                const link = row.querySelector("a.drug-info-link");
                const url = absoluteUrl(link?.getAttribute("href") ?? null);
                const id = url ? new URL(url).searchParams.get("setid") ?? "" : "";
                const packagerRow = [...row.querySelectorAll(".drug-information li")]
                    .find((node) => /^Packager:/i.test(cleanText(node.textContent)));
                const packager = cleanText(packagerRow?.textContent).replace(/^Packager:\s*/i, "");
                return {
                    id,
                    title: cleanText(link?.textContent),
                    ndcCodes: textList(row.querySelector(".ndc-codes")),
                    ...(packager ? { packager } : {}),
                    url,
                };
            }).filter((item) => item.id && item.title && item.url);
            const countText = cleanText(doc.querySelector(".header .count, span.count")?.textContent);
            const totalCount = Number.parseInt(countText.replace(/\D/g, ""), 10) || 0;
            const nextHref = doc.querySelector(".pagination a.next-link")?.getAttribute("href");
            const nextCursor = nextHref
                ? new URL(nextHref, ORIGIN).searchParams.get("page")
                : null;
            log(`searchDrugLabels ${field} "${query}" page ${page}: ${items.length}/${totalCount}`);
            return { items, totalCount, nextCursor };
        },
    });
    action("getDrugLabel", {
        async invoke({ id }) {
            if (!id)
                throw new Error("getDrugLabel: id is required");
            const params = new URLSearchParams({ setid: id });
            const url = `${ORIGIN}/dailymed/drugInfo.cfm?${params}`;
            const doc = await fetchDocument(url);
            const title = cleanText(doc.querySelector("#drug-label")?.textContent);
            if (!title)
                throw new Error(`getDrugLabel: no label found for id ${id}`);
            const metadataRows = [...doc.querySelectorAll(".content-wide > article > ul.drug-information li")];
            const metadata = (label) => {
                const row = metadataRows.find((node) => cleanText(node.querySelector("strong")?.textContent)
                    .toLowerCase().startsWith(label.toLowerCase()));
                return cleanText(row?.textContent).replace(new RegExp(`^${label}\\s*:?\\s*`, "i"), "");
            };
            const sections = [...doc.querySelectorAll(".drug-label-sections .Section[data-sectioncode]")]
                .map((section) => ({
                title: cleanText(section.previousElementSibling?.textContent),
                code: section.getAttribute("data-sectioncode") ?? "",
                text: readableText(section),
            }))
                .filter((section) => section.title && section.text);
            const updated = cleanText(doc.querySelector("#drug-information p.date")?.textContent)
                .replace(/^Updated\s*/i, "");
            const category = cleanText(doc.querySelector("#category")?.textContent);
            const deaSchedule = cleanText(doc.querySelector("#dea-schedule")?.textContent);
            const marketingStatus = cleanText(doc.querySelector("#marketing-status")?.textContent);
            const packager = metadata("Packager");
            const pdfUrl = absoluteUrl(doc.querySelector("a.pdf")?.getAttribute("href") ?? null);
            const xmlZipUrl = absoluteUrl(doc.querySelector("a.xml")?.getAttribute("href") ?? null);
            const officialLabelUrl = absoluteUrl(doc.querySelector("a[href*='fdaDrugXsl.cfm']")?.getAttribute("href") ?? null);
            const result = {
                id,
                title,
                ndcCodes: textList(doc.querySelector("#item-code-s")),
                sections,
                url,
                ...(packager ? { packager } : {}),
                ...(category ? { category } : {}),
                ...(deaSchedule ? { deaSchedule } : {}),
                ...(marketingStatus ? { marketingStatus } : {}),
                ...(updated ? { updated } : {}),
                ...(pdfUrl ? { pdfUrl } : {}),
                ...(xmlZipUrl ? { xmlZipUrl } : {}),
                ...(officialLabelUrl ? { officialLabelUrl } : {}),
            };
            log(`getDrugLabel ${id}: ${sections.length} sections`);
            return result;
        },
    });
});
