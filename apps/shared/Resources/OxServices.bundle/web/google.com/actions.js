const cleanText = value => String(value ?? "").replace(/\s+/g, " ").trim();

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

const ORIGIN = "https://www.google.com";
const normalizedUrl = (value) => {
    try {
        const url = new URL(value, ORIGIN);
        if (url.protocol !== "http:" && url.protocol !== "https:") return null;
        const redirected = (url.hostname === "google.com" || url.hostname.endsWith(".google.com")) && url.pathname === "/url"
            ? url.searchParams.get("q")
            : null;
        if (redirected) {
            try {
                const target = new URL(redirected);
                return target.protocol === "http:" || target.protocol === "https:" ? target.href : null;
            } catch {
                return /^[a-z][a-z\d+.-]*:/i.test(redirected) || redirected.startsWith("//") || /\s/.test(redirected)
                    ? null : url.href;
            }
        }
        return url.href;
    }
    catch {
        return null;
    }
};
const timestamp = (value) => {
    const seconds = Number(value);
    if (!Number.isFinite(seconds) || seconds <= 0)
        return null;
    const date = new Date(seconds * 1000);
    return Number.isFinite(date.getTime()) ? date.toISOString() : null;
};
const boundedLimit = (value) => {
    const parsed = typeof value === "number" ? value : Number(value);
    return Number.isInteger(parsed) ? Math.min(20, Math.max(1, parsed)) : 10;
};
const siteOf = (url) => {
    try {
        return new URL(url).hostname.toLowerCase();
    }
    catch {
        return "";
    }
};
function parseNewsResults(doc, limit) {
    const items = [];
    const seen = new Set();
    const anchors = [...doc.querySelectorAll("a[jsname='YKoRaf'][href]")];
    for (const heading of doc.querySelectorAll("h3")) {
        const anchor = heading.closest("a[href]");
        if (anchor && !anchors.includes(anchor))
            anchors.push(anchor);
    }
    for (const anchor of anchors) {
        const url = normalizedUrl(anchor.href);
        const title = cleanText((anchor.querySelector("[role='heading']") ?? anchor.querySelector("h3"))?.textContent);
        if (!url || !title || seen.has(url))
            continue;
        const site = siteOf(url);
        const sourceElement = anchor.querySelector(".MgUUmf.NUnG9d > span:last-child")
            ?? anchor.querySelector(".KogRLb")
            ?? anchor.querySelector(".BamJPe");
        const source = cleanText(sourceElement?.textContent)
            .split("›")[0]?.trim() || site;
        const publishedAt = timestamp(anchor.querySelector("[data-ts]")?.getAttribute("data-ts") ?? null);
        const publishedText = cleanText((anchor.querySelector("[data-ts]") ?? anchor.querySelector(".UK5aid"))?.textContent);
        seen.add(url);
        items.push({ title, url, site, source, publishedAt, publishedText });
        if (items.length === limit)
            break;
    }
    return items;
}
function parseImageResults(doc, limit, thumbnailFor) {
    const items = [];
    const seen = new Set();
    const append = (sourceUrl, title, image) => {
        const thumbnailUrl = image ? thumbnailFor(image) : null;
        if (!sourceUrl || !title || !thumbnailUrl || seen.has(`${sourceUrl}\n${thumbnailUrl}`))
            return;
        seen.add(`${sourceUrl}\n${thumbnailUrl}`);
        items.push({ title, sourceUrl, site: siteOf(sourceUrl), thumbnailUrl });
    };
    for (const root of doc.querySelectorAll("[jsname='dTDiAc'][data-lpage]")) {
        const sourceUrl = normalizedUrl(root.getAttribute("data-lpage") ?? "");
        const image = root.querySelector("img[alt][id]");
        const title = cleanText(image?.alt);
        append(sourceUrl, title, image);
        if (items.length === limit)
            break;
    }
    if (items.length < limit) {
        for (const row of doc.querySelectorAll("tbody:has(img.DS1iW)")) {
            const image = row.querySelector("img.DS1iW");
            const anchor = image?.closest("a[href]");
            const sourceUrl = normalizedUrl(anchor?.href ?? "");
            const title = cleanText(row.querySelector(".qXLe6d.x3G5ab .fYyStc")?.textContent);
            append(sourceUrl, title, image);
            if (items.length === limit)
                break;
        }
    }
    return items;
}
function parseVideoResults(doc, limit, thumbnailFor) {
    const items = [];
    const seen = new Set();
    for (const heading of doc.querySelectorAll("h3")) {
        const anchor = heading.closest("a[href]");
        const url = normalizedUrl(anchor?.href ?? "");
        const title = cleanText(heading.textContent);
        if (!url || !title || seen.has(url))
            continue;
        const container = heading.closest("div[data-hveid]")
            ?? heading.closest(".Gx5Zad");
        if (!container)
            continue;
        const metadata = [...container.querySelectorAll(".gqF9jc > span")]
            .map((element) => cleanText(element.textContent))
            .filter((value) => value && value !== "·");
        const site = siteOf(url);
        const basicSource = cleanText(container.querySelector(".BamJPe")?.textContent).split("›")[0]?.trim() || "";
        const detailText = cleanText(container.querySelector(".H66NU")?.textContent);
        const image = container.querySelector(".iHxmLe img[id], img[id]");
        seen.add(url);
        items.push({
            title,
            url,
            site,
            source: metadata[0] || basicSource || site,
            creator: metadata.length >= 3 ? metadata[1] ?? null : null,
            snippet: cleanText(container.querySelector(".ITZIwc")?.textContent) || detailText,
            duration: cleanText(container.querySelector(".kSFuOd span")?.textContent)
                || detailText.match(/Duration:\s*([0-9]+(?::[0-9]{2}){1,2})/)?.[1] || "",
            publishedText: metadata.at(-1) ?? cleanText(container.querySelector(".H66NU .UK5aid")?.textContent),
            thumbnailUrl: image ? thumbnailFor(image) : null,
        });
        if (items.length === limit)
            break;
    }
    return items;
}
window.ox.install(({ action }) => {
    const ensureSearchPage = (doc, responseUrl) => {
        const host = new URL(responseUrl, ORIGIN).hostname;
        if (host === "sorry.google.com" || doc.querySelector("form#captcha-form, form[action*='/sorry/']")) {
            throw new Error("Google requires a CAPTCHA");
        }
        if (host === "consent.google.com" || doc.querySelector("form[action*='consent.google.com']")) {
            throw new Error("Google requires consent");
        }
        if (host !== "google.com" && !host.endsWith(".google.com"))
            throw new Error(`Unexpected Google host ${host}`);
        return doc;
    };
    const isExplicitlyEmpty = (doc) => {
        const text = cleanText(doc.querySelector("#topstuff")?.textContent);
        return /did not match any documents|no results found/i.test(text)
            || (doc.location.pathname === "/search" && !!doc.querySelector("#main")
                && !doc.querySelector(".Gx5Zad:not(#st-card), .MjjYud"));
    };
    const thumbnailResolver = () => {
        const google = window.google;
        return (image) => {
            const candidate = google?.pim?.[image.id] ?? google?.ldi?.[image.id]
                ?? image.currentSrc ?? image.getAttribute("data-src") ?? image.getAttribute("src");
            return typeof candidate === "string" && /^https:\/\//.test(candidate) ? candidate : null;
        };
    };
    action("search", {
        async invoke({ query, limit = 10, cursor } = {}) {
            if (!query?.trim()) throw new Error("Search query must not be blank");
            if (cursor) throw new Error("Google web search does not expose continuation");
            const deadline = Date.now() + 12000;
            while (Date.now() < deadline) {
                const doc = ensureSearchPage(document, location.href);
                const items = [], seen = new Set();
                for (const heading of doc.querySelectorAll("h3")) {
                    const link = heading.closest("a[href]");
                    if (!link) continue;
                    const url = normalizedUrl(link.getAttribute("href"));
                    const title = cleanText(heading.textContent);
                    if (!url || !title || seen.has(url)) continue;
                    const parsedUrl = new URL(url);
                    const host = parsedUrl.hostname;
                    if ((host === "google.com" || host.endsWith(".google.com"))
                        && !(parsedUrl.pathname === "/url" && parsedUrl.searchParams.get("q"))) continue;
                    const root = link.closest("div[data-hveid]") ?? link.closest(".MjjYud") ?? link.parentElement?.parentElement;
                    const snippet = cleanText(root?.querySelector(".VwiC3b, .s3v9rd, [data-sncf]")?.textContent) || null;
                    seen.add(url);
                    items.push({ title, url, snippet });
                    if (items.length === limit) break;
                }
                if (items.length) return { items, nextCursor: null, scope: "Public web", coverage: "unknown" };
                if (/did not match any documents|no results found/i.test(cleanText(doc.querySelector("#topstuff")?.textContent))) {
                    return { items: [], nextCursor: null, scope: "Public web", coverage: "complete" };
                }
                await new Promise(resolve => setTimeout(resolve, 150));
            }
            throw new Error("Google search results did not become recognizable; absence of results is unverified");
        },
    });

    action("searchFlights", {
        async invoke({query, limit = 10}) {
            if (!query.trim()) throw new Error("Flight query must not be blank");
            const deadline = Date.now() + 25000;
            while (Date.now() < deadline) {
                ensureSearchPage(document, location.href);
                if (!location.pathname.startsWith('/travel/flights')) throw new Error('Not a Google Flights results page');
                const links = [...document.querySelectorAll('li [role="link"][aria-label]')].filter(e => /Select flight$/.test(e.getAttribute('aria-label') || ''));
                const items = [], seen = new Set();
                for (const link of links) {
                    const row = link.closest('li');
                    const summary = cleanText(link.getAttribute('aria-label'));
                    if (seen.has(summary)) continue;
                    const price = row.querySelector('[role="text"][data-gs][aria-label]');
                    const airline = summary.match(/flight with (.*?)\. Leaves /i);
                    const times = summary.match(/Leaves (.*?) and arrives at (.*?)\. Total duration /i);
                    const duration = summary.match(/Total duration (.*?)\./i);
                    if (!price || !airline || !times || !duration) continue;
                    const bag = row.querySelector('[aria-label*="Learn more about baggage allowance"]');
                    seen.add(summary);
                    items.push({airlines:airline[1],departure:times[1],arrival:times[2],duration:duration[1],stops:cleanText(row.querySelector('.EfT7Ae')?.textContent),priceText:cleanText(price.textContent),priceLabel:cleanText(price.getAttribute('aria-label')),baggage:bag ? cleanText(bag.getAttribute('aria-label')).replace(/ Learn more about baggage allowance$/, '') : null,summary});
                    if (items.length >= limit) break;
                }
                const combos = [...document.querySelectorAll('[role="combobox"]')].filter(e=>e.getClientRects().length).map(e=>cleanText(e.innerText));
                const currency = [...document.querySelectorAll('button,[role="button"]')].find(e=>/^Currency/.test(cleanText(e.innerText)));
                const val = sel => document.querySelector(sel)?.value || '';
                const interpretedSearch = {title:document.title,origin:document.querySelector('input[aria-label^="Where from?"]')?.getAttribute('aria-label') || '',destination:document.querySelector('input[aria-label^="Where to?"]')?.getAttribute('aria-label') || '',departureDate:val('input[placeholder="Departure"]'),returnDate:val('input[placeholder="Return"]'),tripType:combos.find(x=>/^(One way|Round trip|Multi-city)$/.test(x)) || '',passengers:cleanText(document.querySelector('button[aria-label*="change number of passengers"]')?.getAttribute('aria-label')).replace(/, change number of passengers\.$/, ''),cabin:combos.find(x=>/Economy|Business|First|Premium/.test(x)) || '',currency:cleanText(currency?.innerText).replace(/^Currency\s*/, '')};
                if (items.length && interpretedSearch.origin && interpretedSearch.destination && interpretedSearch.departureDate) return {items,nextCursor:null,url:location.href,interpretedSearch,coverage:'partial',fareNotice:'Displayed snapshot in Google ranking order. Prices include required taxes and fees for the interpreted trip and passengers; optional baggage fees may apply. Round-trip quotes cover the trip, not a standalone outbound fare. Verify dates and passenger/cabin interpretation. Prices can change.'};
                const body = document.body.innerText;
                if (/No flights found|No results found/.test(body) && interpretedSearch.origin && interpretedSearch.destination && interpretedSearch.departureDate) return {items:[],nextCursor:null,url:location.href,interpretedSearch,coverage:'unknown',fareNotice:'Google displayed no flights for its interpretation of the query; verify the route, dates, and filters.'};
                await new Promise(resolve=>setTimeout(resolve,200));
            }
            throw new Error('Google Flights results did not become recognizable; query may be ambiguous, unsupported, or still loading. Use explicit route, dates and trip type.');
        }
    });


    action("getFlightQuote", {
        async invoke({itinerary}) {
            if (new URL(location.href).searchParams.get('tfs') !== itinerary) throw new Error('Itinerary routing mismatch');
            const deadline = Date.now()+22000;
            while (Date.now()<deadline) {
                ensureSearchPage(document,location.href);
                const quotes = [...document.querySelectorAll('button[aria-label^="Continue to book with "]')].map(e=>cleanText(e.getAttribute('aria-label'))).map(label=>label.match(/^Continue to book with (.*?) for (.+)$/)).filter(Boolean).map(m=>({providerAndFare:m[1],priceLabel:m[2]}));
                const flights = [...document.querySelectorAll('[role="listitem"]')].filter(e=>e.querySelector('button[aria-label^="Flight details."]')).map(e=>{const text=cleanText(e.textContent);return {summary:cleanText(e.querySelector('button[aria-label^="Flight details."]').getAttribute('aria-label')).replace(/^Flight details\. /,''),flightNumbers:[...new Set([...text.matchAll(/(?:^|[^A-Z])([A-Z0-9]{2}\s+\d{1,4})(?!\d)/g)].map(m=>m[1]))]};});
                const fareBrands = [...document.querySelectorAll('h3')].filter(e=>e.parentElement.parentElement.querySelector('button[aria-label^="Continue to book with "]')).map(e=>({name:cleanText(e.textContent),priceText:cleanText(e.parentElement.querySelector('span')?.textContent),features:[...e.parentElement.parentElement.querySelectorAll('li')].map(x=>cleanText(x.textContent))}));
                if (quotes.length && flights.length) return {url:location.href,title:document.title,flights,quotes:[...new Map(quotes.map(q=>[q.providerAndFare+'|'+q.priceLabel,q])).values()],fareBrands,notice:'Google Flights quotes only, including required taxes and fees for the selected passengers. Optional extras may cost more. No seller checkout or final availability verified. No booking performed.'};
                await new Promise(r=>setTimeout(r,200));
            }
            throw new Error('Google Flights booking summary or quotes did not become recognizable');
        }
    });

    action("listSuggestions", {
        async invoke({ query } = {}) {
            if (!query)
                throw new Error("listSuggestions: query is required");
            const params = new URLSearchParams({ client: "firefox", q: query, hl: "en" });
            const response = await retryFetch(`/complete/s?${params}`, { credentials: "include" });
            if (!response.ok)
                throw new Error(`listSuggestions HTTP ${response.status}`);
            const text = await response.text();
            const json = JSON.parse(text.slice(text.indexOf("[")));
            const items = Array.isArray(json?.[1]) ? json[1].filter((value) => typeof value === "string") : [];
            return { items, nextCursor: null };
        },
    });
    action("searchNews", {
        async invoke({ query, limit } = {}) {
            if (!query)
                throw new Error("searchNews: query is required");
            const doc = ensureSearchPage(document, location.href);
            const items = parseNewsResults(doc, boundedLimit(limit));
            if (!items.length && !isExplicitlyEmpty(doc))
                throw new Error("Google news result markup was not recognized");
            const nextUrl = normalizedUrl(doc.querySelector("a#pnnext[href]")?.getAttribute("href") ?? "");
            const nextCursor = nextUrl ? new URL(nextUrl).searchParams.get("start") : null;
            console.log(`searchNews queryChars=${query.length} items=${items.length}`);
            return { items, nextCursor };
        },
    });
    action("searchImages", {
        async invoke({ query, limit } = {}) {
            if (!query)
                throw new Error("searchImages: query is required");
            const doc = ensureSearchPage(document, location.href);
            const items = parseImageResults(doc, boundedLimit(limit), thumbnailResolver());
            if (!items.length && !isExplicitlyEmpty(doc))
                throw new Error("Google image result markup was not recognized");
            console.log(`searchImages queryChars=${query.length} items=${items.length}`);
            return { items, nextCursor: null };
        },
    });
    action("searchVideos", {
        async invoke({ query, limit } = {}) {
            if (!query)
                throw new Error("searchVideos: query is required");
            const doc = ensureSearchPage(document, location.href);
            const items = parseVideoResults(doc, boundedLimit(limit), thumbnailResolver());
            if (!items.length && !isExplicitlyEmpty(doc))
                throw new Error("Google video result markup was not recognized");
            console.log(`searchVideos queryChars=${query.length} items=${items.length}`);
            return { items, nextCursor: null };
        },
    });
});
