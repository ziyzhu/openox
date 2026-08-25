const ORIGIN = "https://www.google.com";
const cleanMapText = (value) => cleanText(value)
    .replace(/[\uE000-\uF8FF]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
const textAt = (root, selector) => cleanMapText(root.querySelector(selector)?.textContent);
const attributeAt = (root, selector, name) => cleanMapText(root.querySelector(selector)?.getAttribute(name));
const numberFrom = (value) => {
    if (!value.trim())
        return null;
    const parsed = Number(value.replace(/[^0-9.-]/g, ""));
    return Number.isFinite(parsed) ? parsed : null;
};
const integerFrom = (value) => {
    const digits = value.replace(/[^0-9]/g, "");
    if (!digits)
        return null;
    const parsed = Number.parseInt(digits, 10);
    return Number.isFinite(parsed) ? parsed : null;
};
const uniqueText = (values) => {
    const seen = new Set();
    const items = [];
    for (const value of values) {
        const text = cleanText(value);
        if (!text || seen.has(text))
            continue;
        seen.add(text);
        items.push(text);
    }
    return items;
};
const placeDetailText = (values, name) => uniqueText(Array.from(values).map((value) => cleanText(value)
    .replace(/^[·•]\s*/, "")
    .replace(/[\uE000-\uF8FF]/g, " "))).filter((value) => value !== name
    && !/^\d(?:\.\d)?(?:\s*\([\d,]+\))?$/.test(value)
    && !/^\([\d,]+\)$/.test(value));
const normalizedMapsUrl = (value) => {
    try {
        const url = new URL(value, ORIGIN);
        if (url.protocol !== "https:" || (url.hostname !== "google.com" && !url.hostname.endsWith(".google.com")))
            return null;
        if (!url.pathname.startsWith("/maps"))
            return null;
        return url.href;
    }
    catch {
        return null;
    }
};
const normalizedWebUrl = (value) => {
    if (!value.trim())
        return null;
    try {
        const url = new URL(value, ORIGIN);
        return url.protocol === "https:" || url.protocol === "http:" ? url.href : null;
    }
    catch {
        return null;
    }
};
const coordinatesFrom = (value) => {
    const at = value.match(/@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)/);
    const data = value.match(/!3d(-?\d+(?:\.\d+)?)[^!]*!4d(-?\d+(?:\.\d+)?)/);
    const match = data ?? at;
    const latitude = Number(match?.[1]);
    const longitude = Number(match?.[2]);
    return {
        latitude: Number.isFinite(latitude) ? latitude : null,
        longitude: Number.isFinite(longitude) ? longitude : null,
    };
};
const placeIdFrom = (value) => {
    try {
        const url = new URL(value, ORIGIN);
        const explicit = url.searchParams.get("query_place_id");
        if (explicit)
            return explicit;
        const encoded = url.href.match(/!1s([^!]+)/)?.[1];
        return encoded ? decodeURIComponent(encoded) : url.href;
    }
    catch {
        return value;
    }
};
const imageAt = (root) => {
    const image = root.querySelector("button[jsaction*='heroHeaderImage'] img, .aoRNLd img, .ZKCDEc img, .FQ2IWe img, .SpFAAb img");
    return normalizedWebUrl(image?.currentSrc || image?.src || image?.getAttribute("src") || "");
};
const ratingAt = (root) => {
    const visible = textAt(root, ".MW4etd, .F7nice span[aria-hidden='true']");
    const aria = attributeAt(root, "[role='img'][aria-label*='star'], [aria-label*='stars']", "aria-label");
    return numberFrom(visible || aria.match(/\d+(?:\.\d+)?/)?.[0] || "");
};
const reviewCountAt = (root) => {
    const visible = textAt(root, ".UY7F9, .F7nice span:last-child");
    const aria = attributeAt(root, "button[jsaction*='reviewChart'], [aria-label*='review']", "aria-label");
    return integerFrom(visible || aria);
};
function parsePlaceDetails(doc, pageUrl, explicitPlaceId = "") {
    const name = textAt(doc, "h1.DUwDvf");
    if (!name)
        return null;
    const canonical = normalizedMapsUrl(attributeAt(doc, "link[rel='canonical']", "href") || pageUrl) ?? normalizedMapsUrl(pageUrl) ?? `${ORIGIN}/maps`;
    const address = textAt(doc, "button[data-item-id='address'] .Io6YTe, [data-item-id='address']");
    const phone = textAt(doc, "button[data-item-id^='phone:tel:'] .Io6YTe, [data-item-id^='phone:tel:']");
    const websiteElement = doc.querySelector("a[data-item-id='authority'][href]");
    const website = normalizedWebUrl(websiteElement?.href || websiteElement?.getAttribute("href") || "");
    const category = textAt(doc, "button.DkEaL, .DkEaL");
    const hoursLabel = attributeAt(doc, "button[data-item-id='oh'], [data-item-id='oh']", "aria-label");
    const hours = hoursLabel.replace(/^Hours:\s*/i, "");
    const openStatus = textAt(doc, ".ZDu9vd, .o0Svhf");
    const priceLevel = textAt(doc, ".mgr77e, [aria-label*='Price']");
    const coordinates = coordinatesFrom(canonical);
    return {
        id: explicitPlaceId || placeIdFrom(canonical),
        name,
        url: canonical,
        address,
        category,
        rating: ratingAt(doc),
        reviewCount: reviewCountAt(doc),
        priceLevel,
        openStatus,
        hours,
        phone,
        website,
        imageUrl: imageAt(doc),
        ...coordinates,
    };
}
const summaryFromDetails = (details) => ({
    id: details.id,
    name: details.name,
    url: details.url,
    rating: details.rating,
    reviewCount: details.reviewCount,
    details: uniqueText([details.category, details.address, details.priceLevel, details.openStatus]),
    imageUrl: details.imageUrl,
    latitude: details.latitude,
    longitude: details.longitude,
});
function parsePlaceResults(doc, pageUrl, limit) {
    const single = parsePlaceDetails(doc, pageUrl);
    if (single)
        return [summaryFromDetails(single)];
    const items = [];
    const seen = new Set();
    const anchors = doc.querySelectorAll("a.hfpxzc[href*='/maps/'], a[href*='/maps/place/']");
    for (const anchor of anchors) {
        const url = normalizedMapsUrl(anchor.href || anchor.getAttribute("href") || "");
        if (!url)
            continue;
        const card = anchor.closest("[role='article'], div[jsaction]") ?? anchor.parentElement;
        if (!card)
            continue;
        const name = cleanText(anchor.getAttribute("aria-label")) || textAt(card, ".qBF1Pd, h2, h3");
        if (!name)
            continue;
        const id = placeIdFrom(url);
        if (seen.has(id))
            continue;
        const detailChildren = card.querySelectorAll(".W4Efsd span, .UaQhfb span");
        const detailElements = detailChildren.length ? detailChildren : card.querySelectorAll(".W4Efsd");
        const details = placeDetailText(Array.from(detailElements).map((element) => element.textContent), name);
        const coordinates = coordinatesFrom(url);
        seen.add(id);
        items.push({
            id,
            name,
            url,
            rating: ratingAt(card),
            reviewCount: reviewCountAt(card),
            details: details.slice(0, 8),
            imageUrl: imageAt(card),
            ...coordinates,
        });
        if (items.length === limit)
            break;
    }
    return items;
}
const boundedLimit = (value) => {
    const parsed = Number(value);
    return Number.isInteger(parsed) ? Math.min(20, Math.max(1, parsed)) : 10;
};
const decodedSearchCursor = (value, query) => {
    const cursor = cleanText(value);
    if (!cursor)
        return { query, ids: [] };
    try {
        const encoded = cursor.replace(/-/g, "+").replace(/_/g, "/");
        const padding = "=".repeat((4 - encoded.length % 4) % 4);
        const parsed = JSON.parse(decodeURIComponent(atob(encoded + padding)));
        if (parsed?.v !== 1 || parsed?.query !== query || !Array.isArray(parsed?.ids))
            throw new Error();
        const rawIds = parsed.ids;
        if (rawIds.some((id) => typeof id !== "string" || !id))
            throw new Error();
        const ids = rawIds;
        return { query, ids: [...new Set(ids)] };
    }
    catch {
        throw new Error("searchPlaces cursor is invalid for this query");
    }
};
const encodedSearchCursor = ({ query, ids }) => btoa(encodeURIComponent(JSON.stringify({
    v: 1,
    query,
    ids,
}))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
function placeResultPage(items, cursor, limit, rawQuery) {
    const query = cleanText(rawQuery);
    const current = decodedSearchCursor(cursor, query);
    const maximum = boundedLimit(limit);
    const seen = new Set(current.ids);
    const page = items.filter((item) => !seen.has(item.id)).slice(0, maximum);
    const ids = [...current.ids, ...page.map((item) => item.id)];
    return {
        items: page,
        nextCursor: page.length === maximum ? encodedSearchCursor({ query, ids }) : null,
    };
}
const waitFor = async (read, timeoutMs = 8000) => {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        const value = read();
        if (value)
            return value;
        await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw new Error("Google Maps page did not finish rendering");
};
const loadPlaceResults = async (pageUrl, seen, count) => {
    let items = await waitFor(() => {
        const parsed = parsePlaceResults(document, pageUrl, Number.MAX_SAFE_INTEGER);
        return parsed.length ? parsed : null;
    });
    const feed = document.querySelector("[role='feed']");
    const hasEnough = () => items.filter((item) => !seen.has(item.id)).length >= count;
    if (!feed || hasEnough())
        return items;
    const deadline = Date.now() + 15000;
    let changedAt = Date.now();
    while (Date.now() < deadline) {
        feed.scrollTop = feed.scrollHeight;
        feed.dispatchEvent(new Event("scroll", { bubbles: true }));
        await new Promise((resolve) => setTimeout(resolve, 250));
        const parsed = parsePlaceResults(document, pageUrl, Number.MAX_SAFE_INTEGER);
        if (parsed.length > items.length) {
            items = parsed;
            changedAt = Date.now();
        }
        if (hasEnough())
            return items;
        if (/reached the end of the list/i.test(cleanMapText(feed.textContent)))
            return items;
        if (Date.now() - changedAt >= 5000)
            return items;
    }
    return items;
};
function directionsUrl({ origin, destination, originPlaceId, destinationPlaceId, travelMode = "driving", }) {
    if (!cleanText(destination))
        throw new Error("getDirectionsUrl requires a destination");
    if (cleanText(originPlaceId) && !cleanText(origin)) {
        throw new Error("getDirectionsUrl requires origin when originPlaceId is provided");
    }
    const params = new URLSearchParams({ api: "1", destination: cleanText(destination), travelmode: travelMode });
    if (cleanText(origin))
        params.set("origin", cleanText(origin));
    if (cleanText(originPlaceId))
        params.set("origin_place_id", cleanText(originPlaceId));
    if (cleanText(destinationPlaceId))
        params.set("destination_place_id", cleanText(destinationPlaceId));
    return `${ORIGIN}/maps/dir/?${params}`;
}
window.ox.install(1, ({ action, log, lib }) => {
    const { cleanText } = lib;
    action("searchPlaces", {
        async invoke({ query, limit = 10, cursor = "" } = {}) {
            if (!cleanText(query))
                throw new Error("searchPlaces requires a query");
            const normalizedQuery = cleanText(query);
            const maximum = boundedLimit(limit);
            const current = decodedSearchCursor(cursor, normalizedQuery);
            const loaded = await loadPlaceResults(location.href, new Set(current.ids), maximum);
            const result = placeResultPage(loaded, cursor, maximum, normalizedQuery);
            log(`searchPlaces queryChars=${normalizedQuery.length} seen=${current.ids.length} items=${result.items.length} next=${result.nextCursor ?? "end"}`);
            return result;
        },
    });
    action("getPlace", {
        async invoke({ query, placeId = "" } = {}) {
            if (!cleanText(query))
                throw new Error("getPlace requires a query");
            const details = await waitFor(() => parsePlaceDetails(document, location.href, cleanText(placeId)));
            log(`getPlace queryChars=${String(query).length} hasPlaceId=${Boolean(placeId)}`);
            return details;
        },
    });
    action("getDirectionsUrl", {
        async invoke(args = {}) {
            return { url: directionsUrl(args) };
        },
    });
});
