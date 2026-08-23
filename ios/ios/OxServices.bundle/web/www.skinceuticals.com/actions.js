(() => {
  // services/action-lib.ts
  function cleanText(value) {
    return String(value ?? "").replace(/\s+/g, " ").trim();
  }
  function pageCursor(value, firstPage) {
    return Math.max(firstPage, Number.parseInt(value ?? String(firstPage), 10) || firstPage);
  }

  // services/builtin/web/www.skinceuticals.com/actions.ts
  var BASE = "https://www.skinceuticals.com";
  var STORE = "/on/demandware.store/Sites-skinc-us-Site/en_US";
  var absoluteUrl = (value) => {
    const text = cleanText(value);
    if (!text)
      return "";
    try {
      return new URL(text, BASE).href;
    } catch {
      return "";
    }
  };
  var money = (value) => {
    const match = cleanText(value).replace(/,/g, "").match(/-?\d+(?:\.\d+)?/);
    return match ? Number(match[0]) : 0;
  };
  var nullableNumber = (value) => {
    const number = Number(value);
    return Number.isFinite(number) ? number : null;
  };
  var jsonAttribute = (element, name) => {
    const value = element?.getAttribute(name);
    if (!value)
      return null;
    try {
      return JSON.parse(value);
    } catch {
      return null;
    }
  };
  var jsonScripts = (document2) => [...document2.querySelectorAll('script[type="application/ld+json"]')].flatMap((script) => {
    try {
      return [JSON.parse(script.textContent ?? "")];
    } catch {
      return [];
    }
  });
  var schemaType = (value, type) => {
    const candidate = value;
    const types = Array.isArray(candidate?.["@type"]) ? candidate["@type"] : [candidate?.["@type"]];
    return types.includes(type);
  };
  var idFromUrl = (value) => {
    try {
      const segment = new URL(String(value), BASE).pathname.split("/").filter(Boolean).at(-1) ?? "";
      return decodeURIComponent(segment.replace(/\.html$/i, ""));
    } catch {
      return "";
    }
  };
  var availability = (value) => cleanText(value).split("/").at(-1) === "InStock";
  var productSummary = (entry) => {
    const item = entry?.item ?? entry;
    const offer = Array.isArray(item?.offers) ? item.offers[0] : item?.offers;
    const rating = item?.aggregateRating;
    const productUrl = absoluteUrl(item?.url || item?.["@id"]);
    return {
      id: idFromUrl(productUrl) || cleanText(item?.sku),
      sku: cleanText(item?.sku),
      name: cleanText(item?.name),
      description: cleanText(item?.description),
      productUrl,
      image: absoluteUrl(Array.isArray(item?.image) ? item.image[0] : item?.image),
      price: nullableNumber(offer?.price),
      currency: cleanText(offer?.priceCurrency) || null,
      available: availability(offer?.availability),
      ratingValue: nullableNumber(rating?.ratingValue),
      reviewCount: nullableNumber(rating?.reviewCount)
    };
  };
  var nextCursor = (document2) => {
    const href = document2.querySelector("[data-js-load-more], .c-pagination__item.m-number")?.href;
    if (!href)
      return null;
    try {
      return new URL(href, BASE).searchParams.get("start");
    } catch {
      return null;
    }
  };
  var orderDate = (value) => {
    const match = value.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
    if (!match)
      return value;
    return `${match[3]}-${match[1].padStart(2, "0")}-${match[2].padStart(2, "0")}`;
  };
  var parseOrders = (document2) => {
    const items = [...document2.querySelectorAll(".c-account-table__row[data-js-row-item]")].map((row) => {
      const cell = (suffix) => cleanText(row.querySelector(`.c-account-table__cell.${suffix} .c-account-table__cell-value`)?.textContent);
      const detailUrl = absoluteUrl(row.querySelector('a[href*="Order-Details"]')?.href);
      const id = detailUrl ? new URL(detailUrl).searchParams.get("orderNumber") ?? "" : "";
      const trackingNumbers = [...row.querySelectorAll(".c-account-table__cell.m-ship-number li")].map((element) => cleanText(element.textContent).replace(/-\s*Track Shipment$/i, "")).filter((value) => value && value !== "-");
      return {
        id,
        date: orderDate(cell("m-date")),
        status: cell("m-status"),
        total: money(cell("m-total")),
        currency: "USD",
        shippingMethod: cell("m-ship-option"),
        trackingNumbers,
        detailUrl
      };
    }).filter((item) => item.id);
    return { items, nextCursor: nextCursor(document2) };
  };
  var parseCart = (document2) => {
    const form = document2.querySelector("#cartitems");
    const items = [...document2.querySelectorAll(".c-product-table__row.m-row-1[data-lora-datalayer]")].flatMap((row) => {
      const lineItems = jsonAttribute(row, "data-lora-datalayer")?.lineitems;
      const pair = Object.entries(lineItems ?? {})[0];
      if (!pair)
        return [];
      const [lineItemId, lineItem] = pair;
      const product = lineItem?.product ?? {};
      const quantityInput = form?.querySelector(`[name="item_quantity_${CSS.escape(lineItemId)}"]`);
      const quantity = Number(quantityInput?.value ?? product.quantity ?? 0);
      const unitPrice = Number(product.salePrice ?? product.price ?? 0);
      return [{
        lineItemId,
        id: cleanText(product.id),
        sku: cleanText(product.pid || product.upc),
        name: cleanText(product.name || product.title),
        description: cleanText(product.subname || product.description),
        size: cleanText(product.size || product.variant),
        quantity,
        unitPrice,
        total: Math.round(unitPrice * quantity * 100) / 100,
        currency: cleanText(product.currency) || "USD",
        image: absoluteUrl(product.imgUrl),
        productUrl: absoluteUrl(product.url)
      }];
    });
    const totalRows = [...document2.querySelectorAll("#cart-totals .c-cart-summary-table__item")];
    const totalValue = (label) => {
      const row = totalRows.find((candidate) => label.test(cleanText(candidate.querySelector(".m-label")?.textContent)));
      return row ? money(row.querySelector(".m-value")?.textContent) : 0;
    };
    const subtotal = totalValue(/^Subtotal$/i) || items.reduce((sum, item) => sum + item.total, 0);
    const total = totalValue(/Estimated Total/i) || subtotal;
    return { items, subtotal, total, currency: items[0]?.currency ?? "USD" };
  };
  var install = ({ action, retryFetch, log }) => {
    const fetchDocument = async (url) => {
      const response = await retryFetch(url, { credentials: "include" });
      if (!response.ok)
        throw new Error(`${new URL(url, BASE).pathname}: HTTP ${response.status}`);
      const document2 = new DOMParser().parseFromString(await response.text(), "text/html");
      const title = cleanText(document2.title).toLowerCase();
      if (title.includes("just a moment") || title.includes("attention required")) {
        throw new Error("SkinCeuticals requires a browser check. Open the service, complete it, and retry.");
      }
      return document2;
    };
    const fetchCart = async () => parseCart(await fetchDocument(`${BASE}${STORE}/Cart-Show`));
    const fetchOrderHistory = async (cursor = 0, limit = 10) => {
      const parameters = new URLSearchParams({
        start: String(cursor),
        sz: String(limit),
        sort: "date",
        order: "DESC"
      });
      const document2 = await fetchDocument(`${BASE}${STORE}/Order-History?${parameters}`);
      const signedIn = Boolean(document2.querySelector('a[href*="Account-Logout"]'));
      if (!signedIn)
        throw new Error("Sign in to SkinCeuticals to read order history.");
      return { document: document2, ...parseOrders(document2) };
    };
    action("getSignInUrl", {
      async invoke() {
        return { url: `${BASE}/account` };
      }
    });
    action("getSignInState", {
      async invoke() {
        const document2 = await fetchDocument(`${BASE}${STORE}/Account-Profile`);
        return { signedIn: Boolean(document2.querySelector('a[href*="Account-Logout"]')) };
      }
    });
    action("searchProducts", {
      async invoke({ query, cursor, limit = 10, sort = "relevance" }) {
        const text = cleanText(query);
        if (!text)
          throw new Error("Search text cannot be empty.");
        const start = pageCursor(cursor, 0);
        const sortRules = {
          relevance: "best-matches",
          best_sellers: "best-sellers-revenue",
          newest: "newest-first",
          price_low: "price-ascending",
          price_high: "price-descending",
          top_rated: "top-rated"
        };
        const parameters = new URLSearchParams({
          q: text,
          start: String(start),
          sz: String(limit),
          prefn1: "b2bProductFlag",
          prefv1: "false",
          srule: sortRules[sort] ?? sortRules.relevance
        });
        const document2 = await fetchDocument(`${BASE}${STORE}/Search-Show?${parameters}`);
        const list = jsonScripts(document2).find((value) => schemaType(value, "ItemList"));
        const items = (list?.itemListElement ?? []).map(productSummary).filter((item) => item.id && item.name);
        log(`searchProducts offset ${start}: ${items.length} products`);
        return { items, nextCursor: nextCursor(document2) };
      }
    });
    action("getProduct", {
      async invoke({ id }) {
        const productId = cleanText(id);
        if (!productId)
          throw new Error("A product ID or SKU is required.");
        const document2 = await fetchDocument(`${BASE}${STORE}/Product-Show?pid=${encodeURIComponent(productId)}`);
        const structured = jsonScripts(document2);
        const product = structured.find((value) => schemaType(value, "ProductGroup")) ?? structured.find((value) => schemaType(value, "Product"));
        if (!product)
          throw new Error(`Product ${productId} was not found.`);
        const pageData = jsonAttribute(document2.body, "data-lora-datalayer")?.product ?? {};
        const rawVariants = schemaType(product, "ProductGroup") ? product.hasVariant ?? [] : [product];
        const variants = rawVariants.map((variant) => {
          const offer = Array.isArray(variant.offers) ? variant.offers[0] : variant.offers;
          return {
            sku: cleanText(variant.sku),
            size: cleanText(variant.size),
            price: nullableNumber(offer?.price),
            currency: cleanText(offer?.priceCurrency) || null,
            available: availability(offer?.availability),
            productUrl: absoluteUrl(variant.url || variant["@id"]),
            image: absoluteUrl(Array.isArray(variant.image) ? variant.image[0] : variant.image)
          };
        }).filter((variant) => variant.sku);
        const canonical = absoluteUrl(document2.querySelector('link[rel="canonical"]')?.href);
        const rating = product.aggregateRating;
        const result = {
          id: cleanText(product.productGroupID || product.sku) || idFromUrl(canonical),
          name: cleanText(product.name || pageData.title),
          description: cleanText(pageData.description || product.description || document2.querySelector('meta[name="description"]')?.getAttribute("content")),
          productUrl: canonical,
          image: absoluteUrl(pageData.imgUrl || (Array.isArray(product.image) ? product.image[0] : product.image)),
          ratingValue: nullableNumber(rating?.ratingValue),
          reviewCount: nullableNumber(rating?.reviewCount),
          variants
        };
        if (!result.id || !result.name || !result.variants.length)
          throw new Error(`Product ${productId} returned incomplete details.`);
        return result;
      }
    });
    action("getCart", {
      async invoke() {
        return fetchCart();
      }
    });
    action("updateCartItem", {
      async invoke({ sku, quantity }) {
        if (!Number.isInteger(quantity) || quantity < 0 || quantity > 5) {
          throw new Error("Quantity must be a whole number from 0 through 5.");
        }
        const current = await fetchCart();
        const existing = current.items.find((item) => item.sku === sku);
        if (existing) {
          const body = new URLSearchParams({
            [`item_quantity_${existing.lineItemId}`]: String(existing.quantity)
          });
          if (quantity === 0)
            body.set("item_remove", existing.lineItemId);
          else
            body.set(`item_quantity_${existing.lineItemId}`, String(quantity));
          const response = await retryFetch(`${BASE}${STORE}/Cart-Submit?ajax=true`, {
            method: "POST",
            credentials: "include",
            headers: { "Content-Type": "application/x-www-form-urlencoded" },
            body: body.toString()
          });
          if (!response.ok)
            throw new Error(`Cart update: HTTP ${response.status}`);
          await response.text();
        } else if (quantity > 0) {
          const response = await retryFetch(`${BASE}${STORE}/Cart-AddProduct?ajax=true`, {
            method: "POST",
            credentials: "include",
            headers: { "Content-Type": "application/x-www-form-urlencoded" },
            body: new URLSearchParams({ pid: sku, quantity: String(quantity), placement: "ox" }).toString()
          });
          if (!response.ok)
            throw new Error(`Add to cart: HTTP ${response.status}`);
          const result = await response.json();
          if (!result?.uuid)
            throw new Error(cleanText(result?.text?.errorMessage || "SkinCeuticals rejected the cart update."));
        }
        const cart = await fetchCart();
        const updated = cart.items.find((item) => item.sku === sku);
        if (quantity === 0 && updated || quantity > 0 && updated?.quantity !== quantity) {
          throw new Error("The cart did not retain the requested quantity.");
        }
        log(`updateCartItem: ${cart.items.length} cart lines, ${cart.total} ${cart.currency}`);
        return cart;
      }
    });
    action("listOrders", {
      async invoke({ cursor, limit = 10 } = {}) {
        const start = pageCursor(cursor, 0);
        const { items, nextCursor: nextCursor2 } = await fetchOrderHistory(start, limit);
        log(`listOrders offset ${start}: ${items.length} orders`);
        return { items, nextCursor: nextCursor2 };
      }
    });
    action("getPaymentUrl", {
      async invoke() {
        return { url: `${BASE}${STORE}/Cart-Show` };
      }
    });
    action("getPaymentState", {
      async invoke({ since, previousOrderId } = {}) {
        const cart = await fetchCart();
        if (cart.items.length) {
          return { status: "pending", reference: null, total: cart.total, currency: cart.currency, completedAt: null };
        }
        if (since && !/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/.test(since)) {
          throw new Error("Transaction start must use YYYY-MM-DD HH:MM:SS.");
        }
        const confirmationReference = /Order-(?:Confirm|Confirmation)/i.test(location.pathname) ? new URL(location.href).searchParams.get("orderNumber") ?? cleanText(document.body?.textContent).match(/\bSKC_\d+\b/)?.[0] ?? null : null;
        try {
          const { items } = await fetchOrderHistory(0, 10);
          const candidate = confirmationReference ? items.find((order) => order.id === confirmationReference) : previousOrderId ? items.find((order) => order.id !== previousOrderId) : undefined;
          const sinceDate = since?.slice(0, 10);
          if (candidate && (!sinceDate || candidate.date >= sinceDate)) {
            return {
              status: "completed",
              reference: candidate.id,
              total: candidate.total,
              currency: candidate.currency,
              completedAt: candidate.date
            };
          }
        } catch (error) {
          log(`getPaymentState order verification unavailable: ${error instanceof Error ? error.message : String(error)}`);
        }
        return { status: "none", reference: null, total: 0, currency: "USD", completedAt: null };
      }
    });
  };
  var actions_default = install;

  // services/action-runtime.ts
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

  installService("www.skinceuticals.com", actions_default);
})();
