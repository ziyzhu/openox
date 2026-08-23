(() => {
  // services/builtin/web/www.doordash.com/actions.ts
  var ORIGIN = "https://www.doordash.com";
  var clean = (value) => typeof value === "string" ? value.replace(/\s+/g, " ").trim() : "";
  var amount = (unitAmount) => {
    const value = Number(unitAmount);
    return Number.isFinite(value) ? value / 100 : null;
  };
  var money = (value, fallbackCurrency = "USD") => ({
    amount: amount(value?.unitAmount),
    currency: clean(value?.currency) || fallbackCurrency,
    display: clean(value?.displayString) || null
  });
  var cartMoney = (unitAmount, currency) => ({
    amount: amount(unitAmount),
    currency: clean(currency) || "USD",
    display: null
  });
  var install = ({ action, retryFetch, log }) => {
    const graphql = async (operationName, query, variables = {}) => {
      const response = await retryFetch(`${ORIGIN}/graphql/${operationName}?operation=${encodeURIComponent(operationName)}`, {
        method: "POST",
        credentials: "include",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
          "x-channel-id": "marketplace",
          "x-experience-id": "doordash"
        },
        body: JSON.stringify({ operationName, variables, query: clean(query) })
      });
      const text = await response.text();
      if (response.status === 401 || response.status === 403) {
        throw new Error("DoorDash requires sign-in");
      }
      if (!response.ok)
        throw new Error(`DoorDash ${operationName} HTTP ${response.status}`);
      let body;
      try {
        body = JSON.parse(text);
      } catch {
        throw new Error(`DoorDash ${operationName} returned a non-JSON response`);
      }
      if (body?.errors?.length) {
        throw new Error(`DoorDash ${operationName}: ${body.errors[0]?.message ?? "request failed"}`);
      }
      return body?.data;
    };
    const STORE_QUERY = `
    query storeFeed($storeId: ID!) {
      retailStorePageFeed(storeId: $storeId) {
        storeDetails {
          id
          name
          isActive
          coverSquareImgUrl
          storeHeader {
            id
            name
            description
            coverImgUrl
            ratings {
              averageRating
              numRatings
            }
            distanceFromConsumer {
              value
              label
            }
            priceRangeDisplayString
            status {
              delivery {
                isAvailable
                etaDisplayString
                displayUnavailableStatus
              }
            }
          }
        }
      }
    }
  `;
    const SEARCH_QUERY = `
    query convenienceSearchQuery($input: RetailSearchInput!) {
      retailSearch(input: $input) {
        query
        list {
          id
          urlSlug
          name
          description
          storeId
          menuId
          imageUrl
          itemMsid
          displayUnit
          unit
          ratings {
            averageRating
            displayNumRatings
            numOfRatings
          }
          price {
            displayString
            currency
            decimalPlaces
            unitAmount
          }
          quickAddContext {
            isEligible
            defaultQuantity
            nestedOptions
            specialInstructions
            price {
              displayString
              currency
              decimalPlaces
              unitAmount
            }
          }
        }
        legoRetailItems {
          id
          component {
            id
            category
          }
          custom
        }
        pageInfo {
          hasNextPage
          cursor
        }
      }
    }
  `;
    const CART_QUERY = `
    query consumerOrderCart {
      consumerOrderCart {
        id
        hasError
        cartType
        isConsumerPickup
        isConvenienceCart
        fulfillmentType
        cartStatusType
        subtotal
        total
        currencyCode
        shortenedUrl
        restaurant {
          id
          name
          coverImgUrl
          slug
        }
        orders {
          id
          orderItems {
            id
            quantity
            continuousQuantity
            priceDisplayString
            priceOfTotalQuantity
            item {
              id
              name
              imageUrl
              storeId
            }
          }
        }
      }
    }
  `;
    const RECEIPT_QUERY = `
    query getPostCheckoutConsumerOrderReceipt($orderCartId: ID!) {
      getConsumerOrderReceipt(orderCartId: $orderCartId) {
        commissionMessage
        storeName
        disclaimer
        lineItems {
          label
          note
          finalMoney {
            unitAmount
            displayString
          }
          originalMoney {
            unitAmount
            displayString
          }
        }
        orders {
          orderItemsList {
            id
            specialInstructions
            substitutionPreference
            quantity
            originalQuantity
            weightedActualQuantity
            item {
              id
              name
              description
              price
              priceMonetaryFields {
                unitAmount
                currency
                displayString
                decimalPlaces
                sign
              }
            }
            unitPriceMonetaryFields {
              currency
              unitAmount
              displayString
            }
            optionsList {
              itemExtraOption {
                name
              }
            }
          }
        }
      }
    }
  `;
    const fetchStore = async (storeId) => {
      const data = await graphql("storeFeed", STORE_QUERY, { storeId });
      const details = data?.retailStorePageFeed?.storeDetails;
      if (!details)
        throw new Error(`DoorDash store ${storeId} was not found`);
      const header = details.storeHeader ?? {};
      const delivery = header.status?.delivery ?? {};
      return {
        id: String(details.id ?? header.id ?? storeId),
        name: clean(details.name ?? header.name),
        description: clean(header.description) || null,
        url: `${ORIGIN}/store/${encodeURIComponent(String(details.id ?? storeId))}`,
        imageUrl: clean(header.coverImgUrl ?? details.coverSquareImgUrl) || null,
        isActive: Boolean(details.isActive),
        deliveryAvailable: Boolean(delivery.isAvailable),
        eta: clean(delivery.etaDisplayString) || null,
        unavailableReason: clean(delivery.displayUnavailableStatus) || null,
        distance: clean(header.distanceFromConsumer?.label) || null,
        priceRange: clean(header.priceRangeDisplayString) || null,
        rating: Number.isFinite(Number(header.ratings?.averageRating)) ? Number(header.ratings.averageRating) : null,
        ratingCount: Number.isFinite(Number(header.ratings?.numRatings)) ? Number(header.ratings.numRatings) : null
      };
    };
    const fetchCart = async () => {
      const data = await graphql("consumerOrderCart", CART_QUERY);
      const cart = data?.consumerOrderCart;
      if (!cart)
        return null;
      const currency = clean(cart.currencyCode) || "USD";
      const items = (cart.orders ?? []).flatMap((order) => (order?.orderItems ?? []).map((orderItem) => ({
        id: String(orderItem.id ?? ""),
        itemId: String(orderItem.item?.id ?? ""),
        name: clean(orderItem.item?.name),
        quantity: Number(orderItem.quantity ?? orderItem.continuousQuantity ?? 0),
        price: {
          amount: amount(orderItem.priceOfTotalQuantity),
          currency,
          display: clean(orderItem.priceDisplayString) || null
        },
        imageUrl: clean(orderItem.item?.imageUrl) || null,
        storeId: String(orderItem.item?.storeId ?? cart.restaurant?.id ?? "")
      })));
      return {
        id: String(cart.id),
        status: clean(cart.cartStatusType) || null,
        fulfillmentType: clean(cart.fulfillmentType) || null,
        isPickup: Boolean(cart.isConsumerPickup),
        isConvenience: Boolean(cart.isConvenienceCart),
        hasError: Boolean(cart.hasError),
        store: {
          id: String(cart.restaurant?.id ?? ""),
          name: clean(cart.restaurant?.name),
          imageUrl: clean(cart.restaurant?.coverImgUrl) || null,
          url: cart.restaurant?.id ? `${ORIGIN}/store/${encodeURIComponent(String(cart.restaurant.id))}` : null
        },
        subtotal: cartMoney(cart.subtotal, currency),
        total: cartMoney(cart.total, currency),
        items,
        checkoutUrl: `${ORIGIN}/consumer/checkout/`
      };
    };
    const fetchOrders = async (limit) => {
      const response = await retryFetch(`${ORIGIN}/orders`, {
        credentials: "include",
        headers: { Accept: "text/html" }
      });
      const html = await response.text();
      if (response.status === 401 || response.status === 403 || /identity\.doordash\.com/.test(response.url)) {
        throw new Error("DoorDash requires sign-in");
      }
      if (!response.ok)
        throw new Error(`DoorDash order history HTTP ${response.status}`);
      const doc = new DOMParser().parseFromString(html, "text/html");
      const cards = [...doc.querySelectorAll('[data-testid="OrderHistoryOrderItem"]')];
      const seen = new Set;
      const items = [];
      for (const card of cards) {
        const link = [...card.querySelectorAll("a[href]")].find((candidate) => /^\/orders\/[0-9a-f-]+$/i.test(new URL(candidate.getAttribute("href") ?? "", ORIGIN).pathname));
        if (!link)
          continue;
        const url = new URL(link.getAttribute("href") ?? "", ORIGIN);
        const id = url.pathname.split("/").filter(Boolean).at(-1) ?? "";
        if (!id || seen.has(id))
          continue;
        seen.add(id);
        items.push({ id, url: url.toString(), summary: clean(card.textContent) });
        if (items.length >= limit)
          break;
      }
      if (!items.length && /sign.?in/i.test(clean(doc.title))) {
        throw new Error("DoorDash requires sign-in");
      }
      return items;
    };
    const fetchReceipt = async (orderCartId) => {
      const data = await graphql("getPostCheckoutConsumerOrderReceipt", RECEIPT_QUERY, { orderCartId });
      const receipt = data?.getConsumerOrderReceipt;
      if (!receipt)
        throw new Error(`DoorDash order ${orderCartId} was not found`);
      const items = (receipt.orders ?? []).flatMap((order) => (order?.orderItemsList ?? []).map((orderItem) => {
        const itemMoney = orderItem.unitPriceMonetaryFields ?? orderItem.item?.priceMonetaryFields;
        return {
          id: String(orderItem.id ?? ""),
          itemId: String(orderItem.item?.id ?? ""),
          name: clean(orderItem.item?.name),
          description: clean(orderItem.item?.description) || null,
          quantity: Number(orderItem.weightedActualQuantity ?? orderItem.quantity ?? 0),
          originalQuantity: Number(orderItem.originalQuantity ?? orderItem.quantity ?? 0),
          unitPrice: money(itemMoney),
          options: (orderItem.optionsList ?? []).map((option) => clean(option?.itemExtraOption?.name)).filter(Boolean),
          specialInstructions: clean(orderItem.specialInstructions) || null,
          substitutionPreference: clean(orderItem.substitutionPreference) || null
        };
      }));
      const lineItems = (receipt.lineItems ?? []).map((lineItem) => ({
        label: clean(lineItem.label),
        note: clean(lineItem.note) || null,
        amount: money(lineItem.finalMoney),
        originalAmount: lineItem.originalMoney ? money(lineItem.originalMoney) : null
      }));
      const totalLine = [...lineItems].reverse().find((lineItem) => /total/i.test(lineItem.label));
      return {
        id: orderCartId,
        url: `${ORIGIN}/orders/${encodeURIComponent(orderCartId)}`,
        storeName: clean(receipt.storeName),
        commissionMessage: clean(receipt.commissionMessage) || null,
        disclaimer: clean(receipt.disclaimer) || null,
        total: totalLine?.amount ?? null,
        lineItems,
        items
      };
    };
    action("getSignInUrl", {
      async invoke() {
        const query = new URLSearchParams({
          client_id: "1666519390426295040",
          intl: "en-US",
          is_iframe_modal: "true",
          last_login_action: "login",
          last_login_method: "google",
          layout: "identity_web_iframe",
          prompt: "none",
          redirect_uri: `${ORIGIN}/post-login/`,
          response_type: "code",
          scope: "*",
          state: "/"
        });
        return { url: `https://identity.doordash.com/auth?${query}` };
      }
    });
    action("getSignInState", {
      async invoke() {
        const response = await retryFetch(`${ORIGIN}/unified-gateway/notification_preferences/v1/doordash/consumer`, {
          credentials: "include",
          headers: { Accept: "application/json" },
          redirect: "manual"
        });
        if (response.status === 401 || response.status === 403 || response.status === 302) {
          return { signedIn: false };
        }
        if (!response.ok)
          throw new Error(`DoorDash sign-in probe HTTP ${response.status}`);
        return { signedIn: true };
      }
    });
    action("getStore", {
      async invoke({ storeId } = {}) {
        if (!clean(storeId))
          throw new Error("getStore requires storeId");
        return { store: await fetchStore(clean(storeId)) };
      }
    });
    action("searchStoreItems", {
      async invoke({ storeId, query, cursor, limit = 20 } = {}) {
        if (!clean(storeId))
          throw new Error("searchStoreItems requires storeId");
        if (!clean(query))
          throw new Error("searchStoreItems requires query");
        const requestedLimit = Math.max(1, Math.min(50, Number(limit) || 20));
        const data = await graphql("convenienceSearchQuery", SEARCH_QUERY, {
          input: {
            query: clean(query),
            storeId: clean(storeId),
            disableSpellCheck: false,
            limit: requestedLimit,
            origin: "RETAIL_SEARCH",
            filterQuery: "",
            aggregateStoreIds: [],
            isDebug: false,
            ...clean(cursor) ? { cursor: clean(cursor) } : {}
          }
        });
        const result = data?.retailSearch;
        const seen = new Set;
        const items = [];
        const listedItems = [...result?.list ?? []];
        for (const facet of result?.legoRetailItems ?? []) {
          if (facet?.component?.category !== "card.retail_item" || !clean(facet.custom))
            continue;
          try {
            const custom = JSON.parse(facet.custom);
            const itemData = custom?.item_data ?? {};
            const itemPrice = itemData.price ?? {};
            listedItems.push({
              id: itemData.item_id,
              name: itemData.item_name,
              description: custom?.logging?.description,
              imageUrl: custom?.image?.remote?.uri,
              price: {
                unitAmount: itemPrice.unit_amount,
                currency: itemPrice.currency,
                displayString: itemPrice.display_string
              },
              unit: itemData.display_unit || itemData.sold_as_info_short_string,
              ratings: null,
              quickAddContext: {
                isEligible: Boolean(custom?.quantity_stepper),
                defaultQuantity: 1
              }
            });
          } catch {
            log(`searchStoreItems ignored malformed facet ${clean(facet?.id)}`);
          }
        }
        for (const item of listedItems) {
          const id = String(item?.id ?? "");
          if (!id || seen.has(id))
            continue;
          seen.add(id);
          const price = money(item.price ?? item.quickAddContext?.price);
          items.push({
            id,
            storeId: clean(storeId),
            name: clean(item.name),
            description: clean(item.description) || null,
            imageUrl: clean(item.imageUrl) || null,
            price,
            unit: clean(item.unit) || null,
            rating: Number.isFinite(Number(item.ratings?.averageRating)) ? Number(item.ratings.averageRating) : null,
            ratingCount: Number.isFinite(Number(item.ratings?.numOfRatings)) ? Number(item.ratings.numOfRatings) : null,
            additionalVariants: null,
            canQuickAdd: Boolean(item.quickAddContext?.isEligible),
            defaultQuantity: Number(item.quickAddContext?.defaultQuantity ?? 1)
          });
          if (items.length >= requestedLimit)
            break;
        }
        log(`searchStoreItems store=${clean(storeId)} results=${items.length}`);
        return {
          items,
          nextCursor: result?.pageInfo?.hasNextPage ? clean(result.pageInfo.cursor) || null : null
        };
      }
    });
    action("getCart", {
      async invoke() {
        return { cart: await fetchCart() };
      }
    });
    action("listOrders", {
      async invoke({ limit = 10 } = {}) {
        const requestedLimit = Math.max(1, Math.min(10, Number(limit) || 10));
        const items = await fetchOrders(requestedLimit);
        return { items, nextCursor: null };
      }
    });
    action("getOrder", {
      async invoke({ orderCartId } = {}) {
        if (!clean(orderCartId))
          throw new Error("getOrder requires orderCartId");
        return { order: await fetchReceipt(clean(orderCartId)) };
      }
    });
    action("getPaymentUrl", {
      async invoke() {
        return { url: `${ORIGIN}/consumer/checkout/` };
      }
    });
    action("getPaymentState", {
      async invoke({ previousOrderId } = {}) {
        const cart = await fetchCart();
        if (cart?.items.length) {
          return {
            status: "pending",
            reference: cart.id,
            total: cart.total.amount ?? 0,
            currency: cart.total.currency,
            completedAt: null
          };
        }
        try {
          const orders = await fetchOrders(1);
          const newest = orders[0];
          if (newest && previousOrderId && newest.id !== clean(previousOrderId)) {
            const receipt = await fetchReceipt(newest.id);
            return {
              status: "completed",
              reference: newest.id,
              total: receipt.total?.amount ?? 0,
              currency: receipt.total?.currency ?? "USD",
              completedAt: null
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

  installService("www.doordash.com", actions_default);
})();
