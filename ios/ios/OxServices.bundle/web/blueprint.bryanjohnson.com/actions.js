(() => {
  // services/action-lib.ts
  function cleanText(value) {
    return String(value ?? "").replace(/\s+/g, " ").trim();
  }

  // services/builtin/web/blueprint.bryanjohnson.com/actions.ts
  var BASE = "https://blueprint.bryanjohnson.com";
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
  var identifier = (value) => cleanText(value);
  var price = (value) => {
    const number = Number(value);
    return Number.isFinite(number) ? number : 0;
  };
  var plainText = (value) => {
    const document2 = new DOMParser().parseFromString(`<div>${String(value ?? "")}</div>`, "text/html");
    return cleanText(document2.body.textContent);
  };
  var imageUrl = (value) => absoluteUrl(value?.url || value?.src || value);
  var productSummary = (product) => ({
    id: identifier(product?.id),
    handle: cleanText(product?.handle),
    name: cleanText(product?.title),
    description: plainText(product?.body || product?.body_html),
    productUrl: absoluteUrl(product?.url || `/products/${product?.handle ?? ""}`),
    image: imageUrl(product?.featured_image || product?.image || product?.images?.[0]),
    price: price(product?.price ?? product?.price_min ?? product?.variants?.[0]?.price),
    available: Boolean(product?.available ?? product?.variants?.some((variant) => variant?.available))
  });
  var variant = (value) => ({
    id: identifier(value?.id),
    productId: identifier(value?.product_id),
    name: cleanText(value?.title),
    sku: cleanText(value?.sku),
    price: price(value?.price),
    currency: cleanText(value?.price_currency) || "USD",
    available: value?.available === undefined ? null : Boolean(value.available),
    image: imageUrl(value?.featured_image),
    weight: Number.isFinite(Number(value?.weight)) ? Number(value.weight) : null,
    weightUnit: cleanText(value?.weight_unit) || null
  });
  var product = (value) => ({
    ...productSummary(value),
    variants: (value?.variants ?? []).map(variant).filter((item) => item.id)
  });
  var cartItem = (item, currency = "USD") => ({
    variantId: identifier(item?.variant_id ?? item?.id),
    productId: identifier(item?.product_id),
    name: cleanText(item?.product_title || item?.title),
    variantName: cleanText(item?.variant_title),
    sku: cleanText(item?.sku),
    quantity: Number(item?.quantity ?? 0),
    unitPrice: price(item?.final_price ?? item?.price) / 100,
    total: price(item?.final_line_price ?? item?.line_price) / 100,
    currency,
    image: imageUrl(item?.featured_image || item?.image),
    productUrl: absoluteUrl(item?.url),
    sellingPlanId: item?.selling_plan_allocation?.selling_plan?.id === undefined ? null : identifier(item.selling_plan_allocation.selling_plan.id)
  });
  var install = ({ action, retryFetch, log }) => {
    const fetchJson = async (path, init) => {
      const response = await retryFetch(`${BASE}${path}`, { credentials: "include", ...init });
      if (!response.ok)
        throw new Error(`${path}: HTTP ${response.status}`);
      return response.json();
    };
    action("searchProducts", {
      async invoke({ query, limit = 4 }) {
        const text = cleanText(query);
        if (!text)
          throw new Error("Search text cannot be empty.");
        const parameters = new URLSearchParams({
          q: text,
          "resources[type]": "product",
          "resources[limit]": String(limit),
          "resources[options][unavailable_products]": "hide"
        });
        const response = await fetchJson(`/search/suggest.json?${parameters}`);
        const items = (response?.resources?.results?.products ?? []).map(productSummary).filter((item) => item.id && item.name);
        log(`searchProducts: ${items.length} products`);
        return { items, nextCursor: null };
      }
    });
    action("listFavoriteProducts", {
      async invoke({ limit = 4 }) {
        const response = await fetchJson(`/collections/bryans-favorites/products.json?limit=${limit}`);
        const items = (response?.products ?? []).map(product).filter((item) => item.id && item.name);
        log(`listFavoriteProducts: ${items.length} products`);
        return { items, nextCursor: null };
      }
    });
    action("getVariant", {
      async invoke({ id }) {
        const variantId = identifier(id);
        if (!variantId)
          throw new Error("A variant ID is required.");
        const response = await fetchJson(`/variants/${encodeURIComponent(variantId)}.json`);
        const result = variant(response?.product_variant);
        if (!result.id)
          throw new Error(`Variant ${variantId} was not found.`);
        return result;
      }
    });
    action("getCart", {
      async invoke() {
        const response = await fetchJson("/cart.js");
        const currency = cleanText(response?.currency) || "USD";
        return {
          items: (response?.items ?? []).map((item) => cartItem(item, currency)),
          itemCount: Number(response?.item_count ?? 0),
          subtotal: price(response?.items_subtotal_price) / 100,
          total: price(response?.total_price) / 100,
          currency
        };
      }
    });
    action("addCartItem", {
      async invoke({ variantId, quantity, sellingPlanId }) {
        const item = {
          id: Number(variantId),
          quantity
        };
        if (sellingPlanId)
          item.selling_plan = Number(sellingPlanId);
        const response = await fetchJson("/cart/add.js", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            items: [item],
            sections: ["cart-icon-bubble", "mobile-cart-icon-bubble", "cart-drawer"]
          })
        });
        const added = response?.items?.[0];
        if (!added)
          throw new Error("Blueprint did not return the added cart item.");
        log(`addCartItem: variant ${variantId}, quantity ${quantity}`);
        return cartItem(added);
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

  installService("blueprint.bryanjohnson.com", actions_default);
})();
