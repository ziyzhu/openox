(() => {
  // service-sdk/action-lib.ts
  function pageCursor(value, firstPage) {
    return Math.max(firstPage, Number.parseInt(value ?? String(firstPage), 10) || firstPage);
  }

  // services/builtin/web/amazon.com/actions.ts
  var clean = (v) => typeof v === "string" ? v.replace(/ /g, " ").replace(/\s+/g, " ").trim() : "";
  var NON_CONTENT_TEXT_TAGS = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE"]);
  var visibleText = (root) => {
    if (!root)
      return "";
    const parts = [];
    const visit = (node) => {
      if (node.nodeType === 1 && NON_CONTENT_TEXT_TAGS.has(node.tagName.toUpperCase()))
        return;
      if (node.nodeType === 3) {
        if (node.nodeValue)
          parts.push(node.nodeValue);
        return;
      }
      for (const child of node.childNodes)
        visit(child);
    };
    visit(root);
    return clean(parts.join(" "));
  };
  var amazonOrderId = (input) => {
    const match = clean(input).match(/(?:D01-\d{7}-\d{7}|\d{3}-\d{7}-\d{7})/i)?.[0];
    return match?.toUpperCase() ?? null;
  };
  var amazonOrderDateText = (headerText) => {
    const match = clean(headerText).match(/^(?:Order placed|Ordered on|Subscription charged on)\s+(.+)$/i);
    return match?.[1] || null;
  };
  var amazonOrderSearchPath = (query, cursor) => {
    const search = clean(query);
    if (!search)
      throw new Error("searchOrders requires a query");
    const page = pageCursor(cursor, 1);
    const params = new URLSearchParams({ search });
    if (page === 1)
      params.set("opt", "ab");
    else
      params.set("page", String(page));
    return `/your-orders/search?${params}`;
  };
  var amazonOrderHasData = (order) => !!(order.orderId || order.placedDate || order.placedText || order.totalText || order.totalValue != null || order.currency || order.status || order.statusDetail || order.orderDetailsUrl || order.items?.length);
  var amazonOrderPage = (orders) => ({
    items: orders.filter(amazonOrderHasData),
    consumed: orders.length
  });
  var install = ({ action, retryFetch, log }) => {
    const ORIGIN = "https://www.amazon.com";
    const RANKING_ROOTS = {
      bestsellers: "/Best-Sellers/zgbs",
      new_releases: "/gp/new-releases",
      movers_shakers: "/gp/movers-and-shakers"
    };
    const SEARCH_SORTS = {
      featured: "relevanceblender",
      price_asc: "price-asc-rank",
      price_desc: "price-desc-rank",
      reviews: "review-rank",
      newest: "date-desc-rank",
      bestsellers: "exact-aware-popularity-rank"
    };
    const ROBOT_PATTERNS = [
      "we just need to make sure you're not a robot",
      "enter the characters you see below",
      "type the characters you see in this image",
      "to discuss automated access to amazon data"
    ];
    const PRICE_SELECTORS = [
      "#corePrice_feature_div .a-offscreen",
      "#corePriceDisplay_desktop_feature_div .a-offscreen",
      "#corePrice_desktop .a-offscreen",
      "#apex_desktop .a-offscreen",
      "#price_inside_buybox",
      "#priceblock_ourprice",
      "#priceblock_dealprice"
    ];
    const uniqueNonEmpty = (values) => [...new Set(values.map(clean).filter(Boolean))];
    const abs = (href) => {
      const s = clean(href);
      if (!s)
        return "";
      try {
        return new URL(s, ORIGIN).toString();
      } catch {
        return "";
      }
    };
    const extractAsin = (input) => {
      const s = clean(input);
      if (!s)
        return null;
      if (/^[A-Z0-9]{10}$/i.test(s))
        return s.toUpperCase();
      const m = s.match(/\/(?:dp|gp\/product|product-reviews)\/([A-Z0-9]{10})/i);
      return m ? m[1].toUpperCase() : null;
    };
    const productUrlOf = (asin) => `${ORIGIN}/dp/${asin}`;
    const parsePrice = (text) => {
      const s = clean(text);
      const m = s.match(/([$€£])\s*(\d+(?:,\d{3})*(?:\.\d+)?)/);
      if (!m)
        return { priceText: s || null, priceValue: null, currency: null };
      const currency = { $: "USD", "€": "EUR", "£": "GBP" }[m[1]] ?? null;
      return {
        priceText: `${m[1]}${m[2]}`,
        priceValue: Number.parseFloat(m[2].replace(/,/g, "")),
        currency
      };
    };
    const parseRating = (text) => {
      const m = clean(text).match(/(\d+(?:\.\d+)?)\s*out of 5/i);
      return m ? Number.parseFloat(m[1]) : null;
    };
    const parseReviewCount = (text) => {
      const s = clean(text);
      const compact = s.match(/(\d+(?:\.\d+)?)\s*([kKmM])/);
      if (compact) {
        const value = Number.parseFloat(compact[1]);
        const mult = /m/i.test(compact[2]) ? 1e6 : 1000;
        return Number.isFinite(value) ? Math.round(value * mult) : null;
      }
      const m = s.match(/([\d,]+)/);
      return m ? Number.parseInt(m[1].replace(/,/g, ""), 10) : null;
    };
    const isAmazonEntity = (text) => clean(text).toLowerCase().includes("amazon");
    const collapseRepeats = (text) => {
      const out = [];
      for (const word of clean(text).split(" ").filter(Boolean)) {
        if (out[out.length - 1] !== word)
          out.push(word);
      }
      return out.join(" ");
    };
    const extractShipsFrom = (text) => {
      const m = clean(text).match(/Ships from\s+(.+?)(?=Sold by|and Fulfilled by|$)/i);
      return m ? collapseRepeats(m[1].replace(/Ships from/gi, "")) || null : null;
    };
    const extractSoldBy = (text) => {
      const m = clean(text).match(/Sold by\s+(.+?)(?=and Fulfilled by|Ships from|$)/i);
      return m ? collapseRepeats(m[1].replace(/Sold by/gi, "")) || null : null;
    };
    const firstText = (root, selectors) => {
      for (const sel of selectors) {
        const t = clean(root.querySelector(sel)?.textContent);
        if (t)
          return t;
      }
      return "";
    };
    const fetchDoc = async (path, diagnostic) => {
      const url = path.startsWith("http") ? path : ORIGIN + path;
      const response = await retryFetch(url, { credentials: "include" });
      const html = await response.text();
      const doc = new DOMParser().parseFromString(html, "text/html");
      if (diagnostic) {
        const final = new URL(response.url || url, ORIGIN);
        const route = final.origin + final.pathname;
        const title = clean(doc.title).slice(0, 120);
        const bytes = new TextEncoder().encode(html).byteLength;
        log(`${diagnostic}: response status=${response.status} route=${route} bytes=${bytes} title=${JSON.stringify(title)}`);
      }
      const haystack = clean((doc.title || "") + " " + (doc.querySelector("body")?.textContent || "")).toLowerCase();
      if (ROBOT_PATTERNS.some((p) => haystack.includes(p))) {
        log("fetchDoc: robot check served for " + url);
        throw new Error("Amazon served a robot check. Open Amazon in the WebView, clear it, and retry.");
      }
      return doc;
    };
    const imageOf = (el) => abs(el?.getAttribute("src") || el?.getAttribute("data-src") || el?.getAttribute("data-old-hires"));
    const linesSeparatedByBreaks = (root) => {
      if (!root)
        return [];
      const lines = [""];
      const visit = (node) => {
        if (node.nodeType === 1) {
          const tag = node.tagName.toUpperCase();
          if (NON_CONTENT_TEXT_TAGS.has(tag))
            return;
          if (tag === "BR") {
            lines.push("");
            return;
          }
        }
        if (node.nodeType === 3) {
          lines[lines.length - 1] += node.nodeValue || "";
          return;
        }
        for (const child of node.childNodes)
          visit(child);
      };
      visit(root);
      return lines.map(clean).filter(Boolean);
    };
    const isoDate = (text) => {
      const ms = Date.parse(clean(text));
      return Number.isFinite(ms) ? new Date(ms).toISOString().slice(0, 10) : null;
    };
    const FRESH_BRAND = "QW1hem9uIEZyZXNo";
    const csrfFrom = (doc) => clean(doc.querySelector("meta[name='anti-csrftoken-a2z']")?.getAttribute("content") || doc.querySelector("input[name='anti-csrftoken-a2z']")?.getAttribute("value"));
    const decodeOnce = (v) => /%[0-9A-Fa-f]{2}/.test(v) ? (() => {
      try {
        return decodeURIComponent(v);
      } catch {
        return v;
      }
    })() : v;
    const cartOffer = (card) => {
      const form = card.querySelector("form[action*='/cart/add-to-cart']");
      const action2 = form?.getAttribute("action") || "";
      const brandId = action2.match(/local-market\/([^/?]+)/)?.[1] || null;
      const cartType = brandId ? "LOCAL_MARKET" : form ? "RETAIL" : null;
      const field = (name) => clean(form?.querySelector(`input[name='${name}']`)?.getAttribute("value"));
      if (!form)
        return {
          offerListingId: null,
          brandId: null,
          addToCartPath: null,
          cartType: null,
          merchantId: null,
          minOrderQuantity: null,
          maxOrderQuantity: null
        };
      const raw = clean(form.querySelector("input[name='items[0.base][offerListingId]'], input[name*='offerListingId' i]")?.getAttribute("value") || card.querySelector("[data-offer-listing-id]")?.getAttribute("data-offer-listing-id"));
      const minOrderQuantity = Number.parseInt(field("minOrderQuantity"), 10);
      const maxOrderQuantity = Number.parseInt(field("maxOrderQuantity"), 10);
      return {
        offerListingId: raw ? cartType === "LOCAL_MARKET" ? decodeOnce(raw) : raw : null,
        brandId,
        addToCartPath: action2 || null,
        cartType,
        merchantId: field("merchantId") || null,
        minOrderQuantity: Number.isFinite(minOrderQuantity) ? minOrderQuantity : null,
        maxOrderQuantity: Number.isFinite(maxOrderQuantity) ? maxOrderQuantity : null
      };
    };
    const enc = encodeURIComponent;
    const formBody = (pairs) => pairs.map(([k, v]) => k + "=" + enc(v)).join("&");
    const postForm = (url, csrf, pairs) => retryFetch(url, {
      method: "POST",
      credentials: "include",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        "anti-csrftoken-a2z": csrf,
        "x-requested-with": "XMLHttpRequest",
        accept: "text/html,*/*"
      },
      body: formBody(pairs)
    });
    const fetchAuthedDoc = async (path, diagnostic) => {
      const doc = await fetchDoc(path, diagnostic);
      if (clean(doc.title).toLowerCase().includes("sign-in")) {
        throw new Error("Amazon session is signed out. Run getSignInUrl, sign in, then retry.");
      }
      return doc;
    };
    const GATED_PATH = "/gp/css/order-history";
    const probeSignedIn = async () => {
      const res = await retryFetch(ORIGIN + GATED_PATH, { credentials: "include" });
      const doc = new DOMParser().parseFromString(await res.text(), "text/html");
      const href = clean(res.url).toLowerCase();
      const title = clean(doc.title).toLowerCase();
      log(`probeSignedIn: href=${href} title=${title}`);
      return !href.includes("/ap/signin") && !title.includes("amazon sign-in");
    };
    action("getSignInUrl", {
      async invoke() {
        const returnTo = `${ORIGIN}/gp/yourstore/home?` + new URLSearchParams({
          path: "/gp/yourstore/home",
          signIn: "1",
          useRedirectOnSuccess: "1",
          action: "sign-out",
          ref_: "nav_AccountFlyout_signout"
        });
        const params = new URLSearchParams({
          "openid.pape.max_auth_age": "900",
          "openid.return_to": returnTo,
          "openid.assoc_handle": "usflex",
          "openid.mode": "checkid_setup",
          "openid.ns": "http://specs.openid.net/auth/2.0"
        });
        return { url: `${ORIGIN}/ap/signin?${params}` };
      }
    });
    action("getSignInState", {
      async invoke() {
        return { signedIn: await probeSignedIn() };
      }
    });
    action("searchProducts", {
      async invoke({ query, cursor, limit = 20, department, sort = "featured" } = {}) {
        if (!query)
          throw new Error("searchProducts requires a query");
        const page = pageCursor(cursor, 1);
        const baseRank = (page - 1) * limit;
        const dept = department ? `&i=${encodeURIComponent(clean(department))}` : "";
        const sortParam = SEARCH_SORTS[sort] && sort !== "featured" ? `&s=${SEARCH_SORTS[sort]}` : "";
        const doc = await fetchDoc(`/s?k=${encodeURIComponent(clean(query))}${dept}${sortParam}&page=${page}`);
        const cards = [...doc.querySelectorAll('[data-component-type="s-search-result"]')];
        const items = [];
        for (const card of cards) {
          const asin = extractAsin(card.getAttribute("data-asin") || "");
          const link = card.querySelector('a.a-link-normal[href*="/dp/"]');
          const title = clean(card.querySelector("h2")?.textContent);
          if (!asin || !title)
            continue;
          const rawUrl = abs(link?.getAttribute("href"));
          const productUrl = (rawUrl && extractAsin(rawUrl) ? productUrlOf(extractAsin(rawUrl)) : rawUrl) || productUrlOf(asin);
          const price = parsePrice(card.querySelector(".a-price .a-offscreen")?.textContent);
          const ratingText = card.querySelector('[aria-label*="out of 5 stars"]')?.getAttribute("aria-label");
          items.push({
            rank: baseRank + items.length + 1,
            asin,
            title,
            productUrl,
            image: imageOf(card.querySelector("img.s-image")),
            ...price,
            ratingValue: parseRating(ratingText),
            reviewCount: parseReviewCount(card.querySelector('a[href*="#customerReviews"]')?.textContent),
            isSponsored: /sponsored/i.test(card.textContent || ""),
            badges: uniqueNonEmpty([...card.querySelectorAll(".a-badge-text")].map((b) => b.textContent)),
            ...cartOffer(card),
            isPrime: !!card.querySelector('[aria-label="Prime"], .a-icon-prime'),
            deliveryText: visibleText(card.querySelector("[data-cy='delivery-block'], .udm-delivery-block")) || null
          });
          if (items.length >= limit)
            break;
        }
        if (items.length === 0)
          log("searchProducts: no product cards for " + query + " (page " + page + ")");
        const hasNextLink = !!doc.querySelector("a.s-pagination-next:not(.s-pagination-disabled)");
        const nextCursor = (hasNextLink || items.length >= limit) && items.length > 0 ? String(page + 1) : null;
        return { items, nextCursor };
      }
    });
    action("listDepartments", {
      async invoke() {
        const doc = await fetchDoc("/");
        const options = [...doc.querySelectorAll("#searchDropdownBox option, #nav-search-dropdown-card option")];
        const byId = new Map;
        for (const opt of options) {
          const id = clean(opt.getAttribute("value")).replace(/^search-alias=/, "");
          const label = clean(opt.textContent);
          if (!id || id === "aps" || byId.has(id))
            continue;
          byId.set(id, label);
        }
        const departments = [...byId].map(([id, label]) => ({ id, label }));
        if (departments.length === 0)
          log("listDepartments: no department options found");
        return { departments };
      }
    });
    action("getProduct", {
      async invoke({ input } = {}) {
        const asin = extractAsin(input);
        if (!asin)
          throw new Error("getProduct requires an ASIN or product URL");
        const doc = await fetchDoc(`/dp/${asin}`);
        const title = clean(doc.querySelector("#productTitle, #title span")?.textContent);
        if (!title) {
          log("getProduct: no product title for " + asin + " — page likely gated");
          throw new Error(`getProduct: no product found for ${asin} (page may be gated or ASIN invalid)`);
        }
        const ratingText = doc.querySelector("#acrPopover")?.getAttribute("title") || doc.querySelector("#acrPopover")?.textContent || "";
        const price = parsePrice(firstText(doc, PRICE_SELECTORS));
        return {
          asin,
          title,
          productUrl: productUrlOf(asin),
          image: imageOf(doc.querySelector("#landingImage, #imgBlkFront, #main-image")),
          brand: firstText(doc, [
            "#bylineInfo",
            "#productOverview_feature_div tr.po-brand td.a-span9 span",
            "#productOverview_feature_div tr.po-brand td:last-child span"
          ]).replace(/^(?:Brand|Visit the)\s*:?\s*/i, "").replace(/\s+Store$/i, "") || null,
          ...price,
          ratingValue: parseRating(ratingText),
          reviewCount: parseReviewCount(doc.querySelector("#acrCustomerReviewText")?.textContent),
          breadcrumbs: uniqueNonEmpty([...doc.querySelectorAll("#wayfinding-breadcrumbs_feature_div a")].map((a) => a.textContent)),
          bullets: uniqueNonEmpty([...doc.querySelectorAll("#feature-bullets li .a-list-item")].map((li) => li.textContent))
        };
      }
    });
    action("getOffer", {
      async invoke({ input } = {}) {
        const asin = extractAsin(input);
        if (!asin)
          throw new Error("getOffer requires an ASIN or product URL");
        const doc = await fetchDoc(`/dp/${asin}`);
        const merchantInfo = clean(doc.querySelector("#merchant-info")?.textContent);
        const shipsBlob = clean(doc.querySelector("#shipsFromSoldByInsideBuyBox_feature_div")?.textContent || doc.querySelector("#fulfillerInfoFeature_feature_div")?.textContent || doc.querySelector("#merchantInfoFeature_feature_div")?.textContent || doc.querySelector("#tabular-buybox-container")?.textContent || "");
        const soldBy = clean(doc.querySelector("#sellerProfileTriggerId")?.textContent) || extractSoldBy(shipsBlob) || extractSoldBy(merchantInfo) || null;
        const shipsFrom = extractShipsFrom(shipsBlob) || extractShipsFrom(merchantInfo) || null;
        if (!soldBy && !shipsFrom && !merchantInfo) {
          log("getOffer: no buy box facts for " + asin);
          throw new Error(`getOffer: no buy box facts for ${asin} (page may be gated or ASIN invalid)`);
        }
        return {
          asin,
          priceText: parsePrice(firstText(doc, PRICE_SELECTORS)).priceText,
          soldBy,
          shipsFrom,
          isAmazonSold: isAmazonEntity(soldBy),
          isAmazonFulfilled: isAmazonEntity(shipsFrom) || /fulfilled by amazon/i.test(merchantInfo)
        };
      }
    });
    action("listReviews", {
      async invoke({ input, cursor, limit = 10 } = {}) {
        const asin = extractAsin(input);
        if (!asin)
          throw new Error("listReviews requires an ASIN or product URL");
        const page = pageCursor(cursor, 1);
        const parse = (doc) => {
          const averageText = doc.querySelector('[data-hook="rating-out-of-text"]')?.textContent || doc.querySelector("#acrPopover")?.getAttribute("title") || "";
          const totalText = doc.querySelector('[data-hook="total-review-count"]')?.textContent || doc.querySelector("#acrCustomerReviewText")?.textContent || "";
          const qaUrls = [
            ...new Set([...doc.querySelectorAll('a[href*="ask/questions"]')].map((a) => a.getAttribute("href") || "").filter(Boolean).map((href) => href.startsWith("http") ? href : ORIGIN + href))
          ];
          const samples = [...doc.querySelectorAll('[data-hook="review"]')].slice(0, limit).map((card) => {
            const ratingText = card.querySelector('[data-hook="review-star-rating"]')?.textContent || card.querySelector('[data-hook="cmps-review-star-rating"]')?.textContent || "";
            return {
              title: clean(card.querySelector('[data-hook="review-title"]')?.textContent).replace(/^\d+(?:\.\d+)?\s*out of 5 stars\s*/i, "") || null,
              ratingValue: parseRating(ratingText),
              author: clean(card.querySelector(".a-profile-name")?.textContent) || null,
              date: clean(card.querySelector('[data-hook="review-date"]')?.textContent) || null,
              body: clean(card.querySelector('[data-hook="review-body"]')?.textContent) || null,
              verifiedPurchase: !!card.querySelector('[data-hook="avp-badge"]')
            };
          });
          const hasNext = !!doc.querySelector('li.a-last:not(.a-disabled) a, [data-hook="pagination-bar"] li.a-last:not(.a-disabled) a');
          return {
            averageText: clean(averageText),
            totalText: clean(totalText),
            qaUrls,
            samples,
            hasNext
          };
        };
        let parsed = parse(await fetchDoc(`/product-reviews/${asin}?pageNumber=${page}`));
        let usedReviewsPage = true;
        if (!parsed.averageText && !parsed.totalText) {
          parsed = parse(await fetchDoc(`/dp/${asin}`));
          usedReviewsPage = false;
        }
        if (!parsed.averageText && !parsed.totalText && parsed.samples.length === 0) {
          log("listReviews: no review summary for " + asin);
          throw new Error(`listReviews: no reviews found for ${asin} (page may be gated or ASIN invalid)`);
        }
        const nextCursor = usedReviewsPage && parsed.hasNext && parsed.samples.length >= limit ? String(page + 1) : null;
        return {
          asin,
          averageRatingValue: parseRating(parsed.averageText),
          totalReviewCount: parseReviewCount(parsed.totalText),
          qaUrls: parsed.qaUrls,
          items: parsed.samples,
          nextCursor
        };
      }
    });
    action("listOrders", {
      async invoke({ timeFilter = "months-3", orderFilter = "orders", cursor, limit = 10 } = {}) {
        const start = pageCursor(cursor, 0);
        const headerValue = (card, label) => {
          for (const item of card.querySelectorAll(".order-header__header-list-item")) {
            const t = clean(item.textContent);
            if (t.toLowerCase().startsWith(label.toLowerCase()))
              return clean(t.slice(label.length));
          }
          return "";
        };
        const parseCard = (card) => {
          const detailsHref = abs(card.querySelector('a[href*="order-details"]')?.getAttribute("href"));
          const orderId = detailsHref && new URL(detailsHref).searchParams.get("orderID") || headerValue(card, "Order #") || null;
          const placedText = [...card.querySelectorAll(".order-header__header-list-item")].map((item) => amazonOrderDateText(item.textContent)).find(Boolean) || null;
          const total = parsePrice(headerValue(card, "Total"));
          const byKey = new Map;
          for (const box of card.querySelectorAll(".item-box")) {
            const link = box.querySelector('a[href*="/dp/"], a[href*="/gp/product/"]');
            const img = box.querySelector("img");
            const asin = extractAsin(link?.getAttribute("href") || "");
            const item = {
              asin,
              title: clean(link?.textContent) || clean(img?.getAttribute("alt")) || null,
              productUrl: asin ? productUrlOf(asin) : abs(link?.getAttribute("href")) || null,
              image: imageOf(img),
              quantity: Number.parseInt(clean(box.querySelector(".product-image__qty")?.textContent), 10) || 1
            };
            const key = item.asin || item.productUrl || item.title || String(byKey.size);
            const prev = byKey.get(key);
            byKey.set(key, prev ? {
              ...prev,
              title: prev.title || item.title,
              image: prev.image || item.image,
              quantity: Math.max(prev.quantity, item.quantity)
            } : item);
          }
          return {
            orderId,
            placedDate: placedText ? isoDate(placedText) : null,
            placedText,
            totalText: total.priceText,
            totalValue: total.priceValue,
            currency: total.currency,
            status: clean(card.querySelector(".delivery-box__primary-text")?.textContent) || null,
            statusDetail: clean(card.querySelector(".delivery-box__secondary-text")?.textContent) || null,
            orderDetailsUrl: detailsHref || null,
            items: [...byKey.values()]
          };
        };
        const items = [];
        let consumed = 0;
        let totalCount = null;
        let pageHasMore = true;
        while (consumed < limit && pageHasMore) {
          const pageStart = start + consumed;
          const params = new URLSearchParams({ startIndex: String(pageStart) });
          if (orderFilter === "orders")
            params.set("timeFilter", timeFilter);
          else
            params.set("orderFilter", orderFilter);
          const diagnostic = `listOrders: filter=${orderFilter}/${timeFilter} start=${pageStart}`;
          const doc = await fetchAuthedDoc(`/your-orders/orders?${params}`, diagnostic);
          const cards = [...doc.querySelectorAll(".order-card.js-order-card")];
          totalCount = Number.parseInt(clean(doc.querySelector(".num-orders")?.textContent), 10) || totalCount;
          const take = cards.slice(0, limit - consumed);
          const parsed = take.map(parseCard);
          const page = amazonOrderPage(parsed);
          const valid = page.items;
          const withId = parsed.filter((order) => order.orderId || order.orderDetailsUrl).length;
          const withDate = parsed.filter((order) => order.placedDate || order.placedText).length;
          const withTotal = parsed.filter((order) => order.totalText || order.totalValue != null || order.currency).length;
          const withStatus = parsed.filter((order) => order.status || order.statusDetail).length;
          const withItems = parsed.filter((order) => order.items.length > 0).length;
          const hasNext = !!doc.querySelector(".a-pagination li.a-last:not(.a-disabled) a");
          log(`${diagnostic}: cards=${cards.length} selected=${parsed.length} valid=${valid.length} empty=${parsed.length - valid.length} ` + `coverage=id:${withId},date:${withDate},total:${withTotal},status:${withStatus},items:${withItems} ` + `reportedTotal=${totalCount ?? "unknown"} hasNext=${hasNext}`);
          if (cards.length === 0)
            break;
          consumed += page.consumed;
          items.push(...valid);
          pageHasMore = take.length < cards.length || hasNext;
        }
        if (items.length === 0)
          log(`listOrders: no order cards (orderFilter ${orderFilter}, timeFilter ${timeFilter})`);
        const nextStart = start + consumed;
        const more = totalCount != null ? nextStart < totalCount : pageHasMore && consumed > 0;
        return { items, totalCount, nextCursor: more && consumed > 0 ? String(nextStart) : null };
      }
    });
    action("searchOrders", {
      async invoke({ query, cursor } = {}) {
        const path = amazonOrderSearchPath(query, cursor);
        const doc = await fetchAuthedDoc(path, `searchOrders: page=${pageCursor(cursor, 1)}`);
        const records = [...doc.querySelectorAll(".a-section.a-spacing-large.a-spacing-top-large")].filter((record) => record.querySelector('a[href*="order-details"]') && record.querySelector('a[href*="/dp/"], a[href*="/gp/product/"]'));
        const items = records.map((record) => {
          const detailsLink = record.querySelector('a[href*="order-details"]');
          const orderDetailsUrl = abs(detailsLink?.getAttribute("href")) || null;
          const productLinks = [...record.querySelectorAll('a[href*="/dp/"], a[href*="/gp/product/"]')];
          const titleLink = productLinks.find((link) => clean(link.textContent));
          const image = record.querySelector("img");
          const productLink = titleLink || productLinks[0];
          const asin = extractAsin(productLink?.getAttribute("href") || "");
          const placedText = [...record.querySelectorAll("*")].filter((node) => node.children.length === 0).map((node) => amazonOrderDateText(node.textContent)).find(Boolean) || null;
          return {
            orderId: amazonOrderId(orderDetailsUrl),
            placedDate: placedText ? isoDate(placedText) : null,
            placedText,
            totalText: null,
            totalValue: null,
            currency: null,
            status: null,
            statusDetail: null,
            orderDetailsUrl,
            items: [{
              asin,
              title: clean(titleLink?.textContent) || clean(image?.getAttribute("alt")) || null,
              productUrl: asin ? productUrlOf(asin) : abs(productLink?.getAttribute("href")) || null,
              image: imageOf(image),
              quantity: 1
            }]
          };
        });
        const nextLink = doc.querySelector(".a-pagination li.a-last:not(.a-disabled) a");
        const nextPage = nextLink ? new URL(nextLink.getAttribute("href") || "", ORIGIN).searchParams.get("page") : null;
        log(`searchOrders: matches=${items.length} next=${nextPage ?? "none"}`);
        return { items, nextCursor: nextPage };
      }
    });
    action("getOrderDetails", {
      async invoke({ input } = {}) {
        const rawInput = clean(input);
        const orderId = amazonOrderId(rawInput);
        if (!orderId)
          throw new Error("getOrderDetails requires an order id like 114-1234567-1234567 or an order-details URL");
        const allowedPaths = new Set([
          "/your-orders/order-details",
          "/gp/css/order-details",
          "/uff/your-account/order-details"
        ]);
        let requestPath = orderId.startsWith("D01-") ? `/gp/css/order-details?orderID=${encodeURIComponent(orderId)}` : `/your-orders/order-details?orderID=${encodeURIComponent(orderId)}`;
        if (/^(?:https?:\/\/|\/)/i.test(rawInput)) {
          const inputUrl = new URL(rawInput, ORIGIN);
          if (inputUrl.origin !== ORIGIN || !allowedPaths.has(inputUrl.pathname)) {
            throw new Error("getOrderDetails requires an Amazon order-details URL");
          }
          inputUrl.searchParams.set("orderID", orderId);
          requestPath = inputUrl.pathname + "?" + inputUrl.searchParams;
        }
        let doc = await fetchAuthedDoc(requestPath);
        let freshRows = [...doc.querySelectorAll("#item-list-page [id$='-item-grid-row']")];
        if (freshRows.length === 0 && doc.querySelectorAll("[data-component=itemTitle]").length === 0 && !orderId.startsWith("D01-")) {
          const freshDoc = await fetchAuthedDoc(`/uff/your-account/order-details?orderID=${encodeURIComponent(orderId)}`);
          const fallbackRows = [...freshDoc.querySelectorAll("#item-list-page [id$='-item-grid-row']")];
          if (fallbackRows.length > 0) {
            doc = freshDoc;
            freshRows = fallbackRows;
          }
        }
        if (freshRows.length > 0) {
          const orderedText = [...doc.querySelectorAll("#order-summary .a-color-tertiary")].map((el) => clean(el.textContent)).find((text) => /^Ordered\s+/i.test(text)) || "";
          const orderDateText2 = orderedText.replace(/^Ordered\s+/i, "").replace(/\s+\d{1,2}:\d{2}\s*(?:AM|PM)$/i, "") || null;
          const address = [...doc.querySelectorAll("#delivery-destination .a-size-base")].find((el) => clean(el.textContent));
          const payList2 = doc.querySelector(".pmts-payments-instrument-list");
          const payBrand2 = clean(payList2?.querySelector("img")?.getAttribute("alt"));
          const payTail2 = clean(payList2?.textContent).match(/ending in\s*(\d+)/i)?.[1];
          const charges2 = [...doc.querySelectorAll("#order-summary .ufpo-charge-breakdown > .a-row")].map((row) => {
            const label = clean(row.querySelector("dt")?.textContent).replace(/:\s*$/, "");
            const amountCandidates = [...row.querySelectorAll("dd span")].filter((span) => !span.classList.contains("a-text-strike")).map((span) => clean(span.textContent)).filter(Boolean);
            const amountText = amountCandidates.at(-1) || clean(row.querySelector("dd")?.textContent);
            const amountValue = Number.parseFloat(amountText.replace(/[^0-9.-]/g, ""));
            return label && Number.isFinite(amountValue) ? { label, amountText, amountValue } : null;
          }).filter(Boolean);
          const items2 = freshRows.map((row) => {
            const link = row.querySelector('a[href*="/gp/product/"], a[href*="/dp/"]');
            const asin = extractAsin(link?.getAttribute("href") || row.id) || null;
            const quantity = Number.parseInt(clean(row.querySelector(".a-column.a-span1.a-text-center")?.textContent), 10) || 1;
            const total = parsePrice(row.querySelector("[id$='-item-total-price']")?.textContent);
            const priceValue = total.priceValue == null ? null : total.priceValue / quantity;
            const priceText = priceValue == null ? total.priceText : total.currency === "USD" ? `$${priceValue.toFixed(2)}` : String(priceValue);
            return {
              asin,
              title: clean(link?.textContent) || null,
              productUrl: asin ? productUrlOf(asin) : abs(link?.getAttribute("href")) || null,
              image: imageOf(row.querySelector("img")),
              priceText,
              priceValue,
              currency: total.currency,
              quantity,
              merchant: null,
              deliveryFrequency: null,
              returnEligibility: null
            };
          });
          return {
            orderId,
            orderDate: isoDate(orderDateText2),
            orderDateText: orderDateText2,
            shipToLines: linesSeparatedByBreaks(address),
            paymentMethod: payBrand2 ? payBrand2 + (payTail2 ? ` ending in ${payTail2}` : "") : clean(payList2?.textContent) || null,
            charges: charges2,
            items: items2,
            shipments: [],
            invoiceUrl: abs(doc.querySelector("#ufpo-order-invoice-link")?.getAttribute("href")) || null
          };
        }
        const comp = (name) => doc.querySelector(`[data-component=${name}]`);
        const orderDateText = clean(comp("orderDate")?.textContent) || null;
        const shipToLines = [...comp("shippingAddress")?.querySelectorAll("li") ?? []].map((li) => clean(li.textContent)).filter(Boolean);
        const charges = [...doc.querySelectorAll("#od-subtotals .a-row")].map((row) => clean(row.textContent).match(/^(.+?):\s*(-?\$[\d,.]+)$/)).filter(Boolean).map((m) => ({
          label: m[1],
          amountText: m[2],
          amountValue: Number.parseFloat(m[2].replace(/[^0-9.-]/g, ""))
        }));
        const items = [...doc.querySelectorAll("[data-component=itemTitle]")].map((titleEl) => {
          const row = titleEl.closest(".a-fixed-left-grid") || titleEl;
          const link = titleEl.querySelector("a") || row.querySelector('a[href*="/dp/"]');
          const asin = extractAsin(link?.getAttribute("href") || "");
          const within = (name) => clean(row.querySelector(`[data-component=${name}]`)?.textContent);
          const price = parsePrice(row.querySelector("[data-component=unitPrice] .a-offscreen")?.textContent);
          return {
            asin,
            title: clean(titleEl.textContent) || null,
            productUrl: asin ? productUrlOf(asin) : abs(link?.getAttribute("href")) || null,
            image: imageOf(row.querySelector("img")),
            priceText: price.priceText,
            priceValue: price.priceValue,
            currency: price.currency,
            quantity: Number.parseInt(within("quantity"), 10) || 1,
            merchant: within("orderedMerchant").replace(/^Sold by:\s*/i, "") || null,
            deliveryFrequency: within("deliveryFrequency").replace(/^Auto-delivered:\s*/i, "") || null,
            returnEligibility: within("itemReturnEligibility").replace(/^Return items:\s*/i, "") || null
          };
        });
        if (items.length === 0) {
          log("getOrderDetails: no purchased items for " + orderId);
          throw new Error(`getOrderDetails: no details found for ${orderId} (wrong id or signed-out session?)`);
        }
        const shipments = [...doc.querySelectorAll("[data-component=shipments]")].map((sh) => ({
          status: clean(sh.querySelector("[data-component=shipmentStatus]")?.textContent) || null,
          trackingUrl: abs(sh.querySelector('a[href*="ship-track"]')?.getAttribute("href")) || null
        })).filter((shipment) => shipment.status || shipment.trackingUrl);
        const payList = doc.querySelector(".pmts-payments-instrument-list");
        const payBrand = clean(payList?.querySelector("img")?.getAttribute("alt"));
        const payTail = clean(payList?.textContent).match(/ending in\s*(\d+)/i)?.[1];
        return {
          orderId,
          orderDate: isoDate(orderDateText),
          orderDateText,
          shipToLines,
          paymentMethod: payBrand ? payBrand + (payTail ? ` ending in ${payTail}` : "") : clean(payList?.textContent) || null,
          charges,
          items,
          shipments,
          invoiceUrl: abs(doc.querySelector('a[href*="print.html"]')?.getAttribute("href")) || null
        };
      }
    });
    action("trackPackage", {
      async invoke({ input } = {}) {
        const url = clean(input);
        if (!url.includes("ship-track")) {
          throw new Error("trackPackage requires a ship-track URL from getOrderDetails or listOrders");
        }
        const doc = await fetchAuthedDoc(url);
        const container = doc.querySelector("#tracking-events-container");
        const blob = clean(container?.textContent);
        const events = [];
        let date = null;
        for (const row of container?.querySelectorAll(".a-row") ?? []) {
          const text = clean(row.textContent);
          if (!text)
            continue;
          if ((row.getAttribute("class") || "").includes("tracking-event-date")) {
            date = text;
            continue;
          }
          const m = text.match(/^(\d{1,2}:\d{2}\s*[AP]M)\s*(.*)$/i);
          if (m)
            events.push({ date, time: m[1], description: m[2] || null });
        }
        const status = clean(doc.querySelector("#primaryStatus")?.textContent || [...doc.querySelectorAll("h1, h2, h3")].map((h) => clean(h.textContent)).find((t) => /delivered|arriving|out for delivery|shipped|in transit/i.test(t))) || null;
        if (!status && events.length === 0) {
          log("trackPackage: no tracking facts at " + url);
          throw new Error("trackPackage: no tracking information found (link may be stale)");
        }
        return {
          status,
          trackingId: blob.match(/Tracking ID:\s*([A-Z0-9]+)/i)?.[1] ?? null,
          carrier: blob.match(/Delivery facilitated by\s+([A-Za-z ]+?)(?=\s*Tracking|$)/i)?.[1]?.trim() ?? null,
          events
        };
      }
    });
    const cartLineDetails = (doc) => {
      const byAsin = new Map;
      for (const line of doc.querySelectorAll("#sc-active-cart [data-itemid][data-asin]")) {
        const asin = clean(line.getAttribute("data-asin")).toUpperCase();
        const itemId = clean(line.getAttribute("data-itemid"));
        if (!asin || !itemId)
          continue;
        const priceValue = Number.parseFloat(clean(line.getAttribute("data-price")));
        let currency = null;
        try {
          currency = JSON.parse(line.getAttribute("data-subtotal") || "null")?.subtotal?.code || null;
        } catch {}
        const detail = {
          itemId,
          title: clean(line.getAttribute("data-producttitle")) || null,
          productUrl: productUrlOf(asin),
          image: imageOf(line.querySelector(".sc-product-image img, img")),
          priceText: Number.isFinite(priceValue) ? currency === "USD" ? `$${priceValue.toFixed(2)}` : String(priceValue) : null,
          priceValue: Number.isFinite(priceValue) ? priceValue : null,
          currency,
          selected: line.hasAttribute("data-isselected") ? line.getAttribute("data-isselected") === "1" : null,
          inStock: line.hasAttribute("data-outofstock") ? line.getAttribute("data-outofstock") !== "1" : null,
          deliveryText: clean(line.querySelector("[data-cy='delivery-block']")?.textContent) || null
        };
        byAsin.set(asin, [...byAsin.get(asin) || [], detail]);
      }
      return byAsin;
    };
    action("getCart", {
      async invoke() {
        const res = await retryFetch(ORIGIN + "/cart/add-to-cart/get-cart-items?clientName=SiteWideActionExecutor", { credentials: "include" });
        const raw = await res.text();
        let entries;
        try {
          entries = JSON.parse(raw);
        } catch {
          throw new Error("getCart: unexpected cart payload — Amazon session may be signed out");
        }
        const doc = await fetchAuthedDoc("/gp/cart/view.html");
        const details = cartLineDetails(doc);
        const items = entries.map((e) => {
          const asin = clean(e.asin).toUpperCase() || null;
          const detail = asin ? details.get(asin)?.shift() : null;
          return {
            itemId: detail?.itemId || null,
            asin,
            quantity: Number.parseInt(e.quantity, 10) || 1,
            cartType: clean(e.cartType) || null,
            merchantId: clean(e.merchantId) || null,
            title: detail?.title || null,
            productUrl: detail?.productUrl || (asin ? productUrlOf(asin) : null),
            image: detail?.image || "",
            priceText: detail?.priceText || null,
            priceValue: detail?.priceValue ?? null,
            currency: detail?.currency || null,
            selected: detail?.selected ?? null,
            inStock: detail?.inStock ?? null,
            deliveryText: detail?.deliveryText || null
          };
        });
        const subtotals = uniqueNonEmpty(clean(doc.querySelector("#sc-cart-column, #sc-page-content")?.textContent).match(/Subtotal[^:]*:\s*\$[\d,.]+/g) ?? []);
        return { items, subtotals };
      }
    });
    action("deleteCartItem", {
      async invoke({ itemId } = {}) {
        itemId = clean(itemId);
        if (!/^[\w-]+$/.test(itemId))
          throw new Error("deleteCartItem requires a cart line id from getCart");
        const doc = await fetchAuthedDoc("/gp/cart/view.html");
        const lines = [...doc.querySelectorAll("#sc-active-cart [data-itemid][data-asin]")];
        const target = lines.find((line) => clean(line.getAttribute("data-itemid")) === itemId);
        const asin = clean(target?.getAttribute("data-asin")).toUpperCase();
        if (!target || !asin)
          throw new Error("deleteCartItem: the cart line no longer exists");
        const numberAttr = (line, name) => Number.parseFloat(clean(line.getAttribute(name))) || 0;
        const activeItems = lines.map((line) => ({
          itemId: `sc-active-${clean(line.getAttribute("data-itemid"))}`,
          giftable: numberAttr(line, "data-giftable"),
          giftWrapped: numberAttr(line, "data-giftwrapped"),
          quantity: numberAttr(line, "data-quantity"),
          price: numberAttr(line, "data-price"),
          incentivizedCartMessage: clean(line.getAttribute("data-incentivizedcartmessage")),
          nestedItemsQuantity: numberAttr(line, "data-nesteditemsquantity"),
          installments: {},
          isSelected: numberAttr(line, "data-isselected"),
          unifiedDeliveryMessage: line.getAttribute("data-unifieddeliverymessage") || "",
          showLineLevelRecommender: numberAttr(line, "data-showlinelevelrecommender"),
          exceedsSimplificationThreshold: numberAttr(line, "data-exceedssimplificationthreshold"),
          relatedItemIds: []
        }));
        const actionPayload = [{
          type: "DELETE_START",
          payload: {
            itemId,
            list: "activeItems",
            relatedItemIds: [],
            isPrimeAsin: target.getAttribute("data-isprimeasin") === "1"
          }
        }];
        const csrf = csrfFrom(doc);
        const response = await postForm(`${ORIGIN}/cart/ref=ox_sc_cart_actions_1`, csrf, [
          ["submit.cart-actions", "1"],
          ["pageAction", "cart-actions"],
          ["actionPayload", JSON.stringify(actionPayload)],
          ["hasMoreItems", "false"],
          ["addressId", ""],
          ["addressZip", ""],
          ["displayedSavedItemNum", "0"],
          ["activeItems", JSON.stringify(activeItems)],
          ["savedItems", "[]"]
        ]);
        const text = await response.text();
        const ok = response.ok && text.includes(itemId) && /"removed"\s*:\s*"true"/.test(text);
        log(`deleteCartItem: itemId=${itemId} asin=${asin} status=${response.status} ok=${ok}`);
        if (!ok)
          throw new Error("deleteCartItem: Amazon did not confirm that the item was removed");
        return { ok: true, itemId, asin };
      }
    });
    action("addToCart", {
      async invoke(args = {}) {
        const {
          input,
          quantity = 1,
          brandId,
          addToCartPath,
          cartType,
          merchantId,
          minOrderQuantity,
          maxOrderQuantity
        } = args;
        const asin = extractAsin(input);
        if (!asin)
          throw new Error("addToCart requires an ASIN or product URL");
        const qty = Math.max(1, Number.parseInt(String(quantity), 10) || 1);
        const requestedLocal = cartType === "LOCAL_MARKET" || !!brandId || clean(addToCartPath).includes("local-market");
        const searchDoc = await fetchDoc(`/s?k=${encodeURIComponent(asin)}${requestedLocal ? "&i=amazonfresh" : ""}`);
        const card = [...searchDoc.querySelectorAll('[data-component-type="s-search-result"]')].find((candidate) => extractAsin(candidate.getAttribute("data-asin")) === asin);
        const found = cartOffer(card || searchDoc.createDocumentFragment());
        const type = clean(cartType) || found.cartType || (requestedLocal ? "LOCAL_MARKET" : "RETAIL");
        const brand = clean(brandId) || found.brandId || (type === "LOCAL_MARKET" ? FRESH_BRAND : "");
        const path = clean(addToCartPath) || found.addToCartPath || (type === "LOCAL_MARKET" ? `/cart/add-to-cart/local-market/${brand}/ref=ox_atc` : "/cart/add-to-cart?ref=ox_atc");
        const rawOffer = clean(args.offerListingId) || found.offerListingId || "";
        const oli = type === "LOCAL_MARKET" ? decodeOnce(rawOffer) : rawOffer;
        if (!oli)
          throw new Error("addToCart: no purchasable offer found for this product");
        const csrf = csrfFrom(searchDoc);
        const merchant = clean(merchantId) || found.merchantId || "";
        const minQty = Math.max(1, Number.parseInt(String(minOrderQuantity ?? found.minOrderQuantity ?? 1), 10) || 1);
        const maxQty = Math.max(minQty, Number.parseInt(String(maxOrderQuantity ?? found.maxOrderQuantity ?? 999), 10) || 999);
        const pairs = [
          ["anti-csrftoken-a2z", csrf],
          ["clientName", type === "LOCAL_MARKET" ? "EUIC_AddToCartFreshOGS_Search" : "EUIC_AddToCart_Search"],
          ["items[0.base][asin]", asin],
          ["items[0.base][offerListingId]", oli],
          ["items[0.base][quantity]", String(qty)]
        ];
        if (type === "RETAIL") {
          pairs.push(["minOrderQuantity", String(minQty)], ["maxOrderQuantity", String(maxQty)]);
          if (merchant)
            pairs.push(["merchantId", merchant]);
        }
        pairs.push(["submit.addToCart", ""]);
        log(`addToCart: asin=${asin} cartType=${type} qty=${qty} csrf=${csrf ? "yes" : "MISSING"} path=${path.slice(0, 80)}`);
        const res = await postForm(abs(path), csrf, pairs);
        const text = await res.text();
        const count = Number.parseInt((text.match(/"cartCount"\s*:\s*"?(\d+)/) || [])[1] || "", 10);
        const ok = res.status >= 200 && res.status < 400 && /cartCount|"success"|addedToCart|Added to cart|QuantityStepperReplace/i.test(text);
        log(`addToCart: status=${res.status} bodyLen=${text.length} cartCount=${Number.isFinite(count) ? count : "?"} ok=${ok}`);
        if (!ok) {
          const m = new DOMParser().parseFromString(text, "text/html");
          log("addToCart: FAIL title=" + clean(m.querySelector("title")?.textContent) + " h1=" + clean(m.querySelector("h1")?.textContent) + " body=" + clean(m.querySelector("body")?.textContent).slice(0, 240));
        }
        return { ok, asin, quantity: qty, cartCount: Number.isFinite(count) ? count : null };
      }
    });
    const loadCheckout = async (brand) => {
      const doc = await fetchDoc(`/checkout/entry/cart?pipelineType=Chewbacca&local_market=${brand}`);
      const html = doc.documentElement?.outerHTML || "";
      const purchaseId = html.match(/\/checkout\/p\/(p-[\w-]+)\//)?.[1] || html.match(/["'](?:obfuscatedId|purchaseId)["']\s*:\s*["'](p-[\w-]+)/)?.[1] || null;
      const csrf = csrfFrom(doc);
      log(`loadCheckout: purchaseId=${purchaseId || "MISSING"} csrf=${csrf ? "yes" : "no"}`);
      return { doc, purchaseId, csrf };
    };
    const checkoutSummary = (doc) => {
      const text = clean(doc.querySelector("body")?.textContent);
      const grab = (label) => text.match(label)?.[1] || null;
      return {
        orderTotal: grab(/Order total:?\s*(\$[\d,.]+)/i),
        subtotal: grab(/Subtotal[^:]*:?\s*(\$[\d,.]+)/i),
        deliveryFee: grab(/Delivery(?:\s*fee)?:?\s*(\$[\d,.]+|Free)/i),
        estimatedTax: grab(/(?:Estimated\s*)?tax:?\s*(\$[\d,.]+)/i),
        tip: grab(/Tip:?\s*(\$[\d,.]+)/i),
        deliveryWindow: clean(doc.querySelector("[data-testid*='slot'], [class*='slot-time'], [class*='deliveryWindow']")?.textContent).slice(0, 120) || null
      };
    };
    action("getCheckout", {
      async invoke({ brandId } = {}) {
        const brand = clean(brandId) || FRESH_BRAND;
        const { doc, purchaseId, csrf } = await loadCheckout(brand);
        if (!purchaseId)
          throw new Error("getCheckout: no checkout in progress — add items to the cart first");
        return { purchaseId, csrf, brandId: brand, ...checkoutSummary(doc) };
      }
    });
    action("setTip", {
      async invoke({ amount, purchaseId, csrf } = {}) {
        const value = Number(amount);
        if (!Number.isFinite(value) || value < 0)
          throw new Error("setTip requires a non-negative amount");
        purchaseId = clean(purchaseId);
        csrf = clean(csrf);
        if (!purchaseId || !csrf)
          throw new Error("setTip requires purchaseId and csrf from getCheckout");
        const res = await postForm(`${ORIGIN}/checkout/p/${purchaseId}/tips?referrer=spc`, csrf, [
          ["amount", String(value)],
          ["currencyCode", "USD"],
          ["isClientTimeBased", "1"],
          ["pipelineType", "Chewbacca"],
          ["referrer", "spc"],
          ["programReliable", "1"],
          ["purchasePrograms", "FRESH"]
        ]);
        const ok = res.status >= 200 && res.status < 400;
        log(`setTip: purchaseId=${purchaseId} amount=${value} status=${res.status} ok=${ok}`);
        return { ok, purchaseId, amount: value };
      }
    });
    action("placeOrder", {
      async invoke({ purchaseId, csrf } = {}) {
        purchaseId = clean(purchaseId);
        csrf = clean(csrf);
        if (!purchaseId || !csrf)
          throw new Error("placeOrder requires purchaseId and csrf from getCheckout");
        const res = await postForm(`${ORIGIN}/checkout/p/${purchaseId}/spc/place-order?pipelineType=Chewbacca&purchasePrograms=FRESH&referrer=spc`, csrf, [
          ["anti-csrftoken-a2z", csrf],
          ["hasWorkingJavascript", "1"],
          ["placeYourOrder1", "1"]
        ]);
        const text = await res.text();
        const placed = res.status === 302 || /thankyou|thank you|order placed|order-confirmation/i.test(text);
        const orderId = text.match(/order(?:Id|Number)["'\s:=]+([\dA-Z-]{10,})/i)?.[1] || null;
        log(`placeOrder: purchaseId=${purchaseId} status=${res.status} placed=${placed} orderId=${orderId || "?"}`);
        return { ok: placed, purchaseId, orderId };
      }
    });
    action("listBuyAgain", {
      async invoke({ limit = 30 } = {}) {
        const doc = await fetchAuthedDoc("/gp/buyagain");
        const byAsin = new Map;
        for (const el of doc.querySelectorAll("[data-asin]")) {
          const asin = extractAsin(el.getAttribute("data-asin"));
          if (!asin)
            continue;
          const entry = byAsin.get(asin) ?? {
            asin,
            title: null,
            productUrl: productUrlOf(asin),
            image: "",
            priceText: null,
            priceValue: null,
            currency: null
          };
          entry.title ||= clean(el.querySelector("[class*=asinTitle], .a-truncate-full")?.textContent) || null;
          entry.image ||= imageOf(el.querySelector("img"));
          if (entry.priceText == null) {
            const price = parsePrice(el.querySelector(".a-price .a-offscreen")?.textContent);
            if (price.priceValue != null)
              Object.assign(entry, price);
          }
          byAsin.set(asin, entry);
        }
        const items = [...byAsin.values()].filter((i) => i.title).slice(0, limit);
        if (items.length === 0)
          log("listBuyAgain: no buy-again items");
        return { items, nextCursor: null };
      }
    });
    action("listWishlists", {
      async invoke() {
        const res = await retryFetch(ORIGIN + "/nav/ajax/wishlist?wishlistItems=wishlist&ajaxTemplate=wishlist", { credentials: "include" });
        const raw = await res.text();
        let lists = [];
        try {
          const data = JSON.parse(JSON.parse(raw).data);
          for (const group of data?.wishlistItems?.template?.data?.items ?? []) {
            for (const it of group?.items ?? []) {
              const url = abs(it.url);
              const id = url.match(/\/wishlist\/ls\/([A-Z0-9]+)/i)?.[1] ?? null;
              if (id)
                lists.push({ id, name: clean(it.text), url });
            }
          }
        } catch {
          throw new Error("listWishlists: unexpected payload — Amazon session may be signed out");
        }
        return { items: lists, nextCursor: null };
      }
    });
    action("listWishlistItems", {
      async invoke({ list, cursor, limit = 30 } = {}) {
        const id = clean(list).match(/(?:\/wishlist\/ls\/)?([A-Z0-9]{11,15})/i)?.[1];
        if (!id)
          throw new Error("listWishlistItems requires a wishlist id or URL from listWishlists");
        const params = new URLSearchParams({ viewType: "list" });
        if (cursor)
          params.set("lek", cursor);
        const doc = await fetchAuthedDoc(`/hz/wishlist/ls/${id}?${params}`);
        const items = [];
        for (const li of doc.querySelectorAll("#g-items li")) {
          const itemId = li.getAttribute("data-itemid") || li.getAttribute("data-itemId");
          if (!itemId)
            continue;
          const link = li.querySelector("a[id^=itemName]");
          const href = abs(link?.getAttribute("href"));
          const asin = extractAsin(href);
          const price = parsePrice(li.querySelector(".a-price .a-offscreen")?.textContent);
          items.push({
            itemId,
            asin,
            title: clean(link?.getAttribute("title")) || clean(link?.textContent) || null,
            productUrl: asin ? productUrlOf(asin) : href || null,
            image: imageOf(li.querySelector("img")),
            priceText: price.priceText,
            priceValue: price.priceValue,
            currency: price.currency,
            byline: clean(li.querySelector("[id^=item-byline]")?.textContent) || null,
            addedText: clean(li.querySelector("[id^=itemAddedDate], .dateAddedText")?.textContent).replace(/^Item added\s*/i, "") || null
          });
          if (items.length >= limit)
            break;
        }
        const lek = doc.querySelector("input[name=lastEvaluatedKey]")?.getAttribute("value");
        const done = !!doc.querySelector("#endOfListMarker");
        if (items.length === 0 && !done)
          log("listWishlistItems: no items parsed for " + id);
        return { items, nextCursor: !done && lek ? lek : null };
      }
    });
    action("listSubscriptions", {
      async invoke() {
        const res = await retryFetch(ORIGIN + "/auto-deliveries/ajax/subscriptionList?deviceType=desktop&deviceContext=web", { credentials: "include" });
        const doc = new DOMParser().parseFromString(await res.text(), "text/html");
        if (clean(doc.title).toLowerCase().includes("sign-in")) {
          throw new Error("Amazon session is signed out. Run getSignInUrl, sign in, then retry.");
        }
        const items = [...doc.querySelectorAll(".subscription-card")].filter((card) => !card.querySelector(".store-front-ingress-message-container") && !(card.getAttribute("class") || "").includes("store-front-ingress")).map((card) => {
          const link = card.querySelector('a[href*="/dp/"], a[href*="/auto-deliveries/"]');
          return {
            title: clean(card.querySelector("img")?.getAttribute("alt")) || clean(link?.getAttribute("title")) || null,
            url: abs(link?.getAttribute("href")) || null,
            image: imageOf(card.querySelector("img")),
            detailsText: clean(card.textContent)
          };
        });
        log("listSubscriptions: " + items.length + " cards");
        return { items, nextCursor: null };
      }
    });
    action("getPrimeMembership", {
      async invoke() {
        const doc = await fetchAuthedDoc("/gp/primecentral");
        const pairValue = (label) => {
          for (const el of doc.querySelectorAll("[class*=mc-menu-head-container]")) {
            const t = clean(el.textContent);
            if (t.toLowerCase().startsWith(label.toLowerCase()))
              return clean(t.slice(label.length)) || null;
          }
          return null;
        };
        const planBox = [...doc.querySelectorAll("[class*=box-lumix]")].find((box) => /current membership/i.test(box.textContent || ""));
        const plan = clean(planBox?.querySelector("[class*=prime-string-head]")?.textContent) || null;
        const priceText = clean(planBox?.querySelector("[class*=price-text]")?.textContent) || "";
        const price = parsePrice(priceText);
        const renewalText = pairValue("Renewal Date");
        const lastPaymentText = pairValue("Last Payment");
        if (!plan && !renewalText) {
          log("getPrimeMembership: no membership facts found");
          throw new Error("getPrimeMembership: no Prime membership found for this account");
        }
        return {
          memberName: clean(doc.querySelector("[class*=mc-profile-name]")?.textContent) || null,
          plan,
          priceText: price.priceText,
          priceValue: price.priceValue,
          currency: price.currency,
          billingPeriod: priceText.match(/\/\s*(month|year)/i)?.[1]?.toLowerCase() ?? null,
          renewalDate: isoDate(renewalText),
          renewalText,
          lastPaymentDate: isoDate(lastPaymentText),
          lastPaymentText
        };
      }
    });
    action("listRankingCategories", {
      async invoke({ list = "bestsellers" } = {}) {
        const root = ORIGIN + (RANKING_ROOTS[list] || RANKING_ROOTS.bestsellers);
        const doc = await fetchDoc(root);
        const seen = new Set;
        const items = [...doc.querySelectorAll("#zg-left-col a[href*='/zgbs/'], #zg-left-col a[href*='/new-releases/'], #zg-left-col a[href*='/movers-and-shakers/'], .zg-browse-group a")].flatMap((link) => {
          const name = clean(link.textContent);
          const url = abs(link.getAttribute("href"));
          if (!name || !url || seen.has(url))
            return [];
          seen.add(url);
          return [{ name, url }];
        });
        if (items.length === 0)
          log("listRankingCategories: no categories for " + list);
        return { items, nextCursor: null };
      }
    });
    action("listRankings", {
      async invoke({ list = "bestsellers", category, cursor, limit = 30 } = {}) {
        const root = clean(category) ? abs(category) : ORIGIN + (RANKING_ROOTS[list] || RANKING_ROOTS.bestsellers);
        if (!root)
          throw new Error("listRankings requires a category URL returned by listRankingCategories");
        const seen = new Set;
        const items = [];
        const firstPage = pageCursor(cursor, 1);
        let lastPage = firstPage;
        let hasMore = false;
        for (let pg = firstPage;pg < firstPage + 4 && items.length < limit; pg++) {
          lastPage = pg;
          const sep = root.includes("?") ? "&" : "?";
          const doc = await fetchDoc(pg === 1 ? root : `${root}${sep}pg=${pg}`);
          const cards = [...doc.querySelectorAll(".p13n-sc-uncoverable-faceout, .zg-grid-general-faceout, [data-asin][class*='p13n']")];
          if (cards.length === 0)
            break;
          hasMore = !!doc.querySelector(".a-pagination li.a-last:not(.a-disabled) a") || cards.length > limit - items.length;
          let added = 0;
          for (const card of cards) {
            const link = card.querySelector('a[href*="/dp/"], a[href*="/gp/product/"]');
            const asin = extractAsin(card.getAttribute("data-asin") || "") || extractAsin(link?.getAttribute("href") || "");
            const key = asin || abs(link?.getAttribute("href"));
            if (!key || seen.has(key))
              continue;
            seen.add(key);
            const title = clean(card.querySelector("[class*='line-clamp']")?.textContent || card.querySelector("img")?.getAttribute("alt") || card.querySelector('a[href*="/dp/"]')?.textContent);
            if (!title)
              continue;
            const rankText = clean(card.querySelector(".zg-bdg-text, [class*='rank']")?.textContent);
            const price = parsePrice(card.querySelector(".a-price .a-offscreen, .a-color-price")?.textContent);
            const ratingText = card.querySelector('[aria-label*="out of 5 stars"]')?.getAttribute("aria-label");
            items.push({
              rank: Number.parseInt(rankText.replace(/\D/g, ""), 10) || items.length + 1,
              asin,
              title,
              productUrl: asin ? productUrlOf(asin) : abs(link?.getAttribute("href")) || null,
              image: imageOf(card.querySelector("img")),
              ...price,
              ratingValue: parseRating(ratingText),
              reviewCount: parseReviewCount(card.querySelector('a[href*="#customerReviews"], .a-size-small')?.textContent)
            });
            added++;
            if (items.length >= limit)
              break;
          }
          if (added === 0)
            break;
        }
        if (items.length === 0)
          log("listRankings: no ranked items for " + list);
        return { items: items.slice(0, limit), nextCursor: hasMore ? String(lastPage + 1) : null };
      }
    });
  };
  var actions_default = install;

  // service-sdk/action-runtime.ts
  var patternMatches = (pattern, value) => {
    pattern.lastIndex = 0;
    const matched = pattern.test(value);
    pattern.lastIndex = 0;
    return matched;
  };
  function installFetchCapture(target) {
    const registrations = new Set;
    const recent = [];
    const matching = (url) => Array.from(registrations).filter((registration) => patternMatches(registration.pattern, url));
    const settle = (matched, result) => {
      for (const registration of matched) {
        if (!registrations.delete(registration))
          continue;
        clearTimeout(registration.timeout);
        if ("error" in result)
          registration.reject(result.error);
        else
          registration.resolve(result.value);
      }
    };
    const canReplay = (url) => {
      try {
        const page = new URL(target.location.href);
        const request = new URL(url, page);
        return request.hostname === page.hostname && /^\/(?:api|web_api)\//.test(request.pathname);
      } catch {
        return false;
      }
    };
    const capture = (url, read) => {
      const matched = matching(url);
      const replayable = canReplay(url);
      if (matched.length === 0 && !replayable)
        return;
      const value = read();
      if (replayable) {
        const entry = { url, value };
        recent.push(entry);
        while (recent.length > 32)
          recent.shift();
        value.catch(() => {
          const index = recent.indexOf(entry);
          if (index >= 0)
            recent.splice(index, 1);
        });
      }
      if (matched.length === 0)
        return;
      value.then((value2) => settle(matched, { value: value2 }), (error) => settle(matched, {
        error: new Error(`captured ${url} returned invalid JSON: ${String(error?.message ?? error)}`)
      }));
    };
    target.oxFetchCapture = (pattern, options) => {
      if (options?.replayLatest) {
        for (let index = recent.length - 1;index >= 0; index--) {
          if (patternMatches(pattern, recent[index].url))
            return recent[index].value;
        }
      }
      return new Promise((resolve, reject) => {
        const timeoutMs = options?.timeoutMs ?? 1e4;
        const registration = {};
        registration.pattern = pattern;
        registration.resolve = resolve;
        registration.reject = reject;
        registration.timeout = setTimeout(() => {
          if (!registrations.delete(registration))
            return;
          reject(new Error(`fetch capture timed out after ${timeoutMs}ms for ${pattern}`));
        }, timeoutMs);
        registrations.add(registration);
      });
    };
    const originalFetch = target.fetch.bind(target);
    target.fetch = (input, init) => originalFetch(input, init).then((response) => {
      const url = input instanceof Request ? input.url : String(input);
      capture(url, () => response.clone().json());
      return response;
    });
    const XHR = target.XMLHttpRequest;
    if (!XHR)
      return;
    const urls = new WeakMap;
    const originalOpen = XHR.prototype.open;
    const originalSend = XHR.prototype.send;
    XHR.prototype.open = function(...args) {
      urls.set(this, String(args[1] ?? ""));
      return originalOpen.apply(this, args);
    };
    XHR.prototype.send = function(...args) {
      this.addEventListener("loadend", () => {
        const url = urls.get(this) ?? this.responseURL;
        capture(url, async () => {
          if (this.responseType === "json")
            return this.response;
          return JSON.parse(this.responseText);
        });
      }, { once: true });
      return originalSend.apply(this, args);
    };
  }
  function installService(domain, installer) {
    installFetchCapture(window);
    const log = (msg) => {
      try {
        window.webkit?.messageHandlers?.oxConsole?.postMessage({
          level: "log",
          msg: `[service:${domain}] ${msg}`
        });
      } catch {}
    };
    const retryFetch = async (input, init, opts) => {
      const retries = opts?.retries ?? 3;
      const delay = opts?.delay ?? 400;
      const factor = opts?.factor ?? 2;
      const url = typeof input === "string" ? input : input.url;
      for (let attempt = 0;; attempt++) {
        try {
          const response = await window.fetch(input, init);
          const retryable = response.status === 408 || response.status === 429 || response.status >= 500 && response.status <= 599;
          if (response.ok || !retryable || attempt >= retries)
            return response;
          log(`retryFetch: status ${response.status}, attempt ${attempt + 1}/${retries}, url=${url}`);
        } catch (error) {
          const message = String(error?.message ?? "");
          const retryable = message.includes("Load failed") || message.includes("NetworkError") || message.includes("Failed to fetch");
          if (!retryable || attempt >= retries)
            throw error;
          log(`retryFetch: network ${JSON.stringify(message)}, attempt ${attempt + 1}/${retries}, url=${url}`);
        }
        await new Promise((resolve) => setTimeout(resolve, delay * Math.pow(factor, attempt)));
      }
    };
    const actions = new Map;
    const action = (name, definition) => {
      if (actions.has(name))
        throw new Error(`duplicate action: ${name}`);
      if (typeof definition?.invoke !== "function")
        throw new Error(`action ${name} has no invoke function`);
      actions.set(name, definition.invoke);
    };
    try {
      installer({ action, retryFetch, log });
    } catch (error) {
      log(`service installer threw: ${String(error?.stack ?? error?.message ?? error)}`);
      throw error;
    }
    const invoke = async (name, args) => {
      const handler = actions.get(name);
      if (!handler)
        throw new Error(`unknown action: ${name}`);
      try {
        return await handler(args ?? {});
      } catch (error) {
        log(`action ${JSON.stringify(name)} threw: ${String(error?.stack ?? error?.message ?? error)}`);
        throw new Error(`action ${JSON.stringify(name)} failed: ${String(error?.message ?? error)}`);
      }
    };
    const runtime = {
      callServiceAction: (name, args) => invoke(name, args)
    };
    window.ox = runtime;
  }

  installService("amazon.com", actions_default);
})();
