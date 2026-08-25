const ORIGIN = "https://www.doordash.com";
const clean = (value) => typeof value === "string" ? value.replace(/\s+/g, " ").trim() : "";
const amount = (unitAmount) => {
    const value = Number(unitAmount);
    return Number.isFinite(value) ? value / 100 : null;
};
const money = (value, fallbackCurrency = "USD") => ({
    amount: amount(value?.unitAmount),
    currency: clean(value?.currency) || fallbackCurrency,
    display: clean(value?.displayString) || null,
});
const cartMoney = (unitAmount, currency) => ({
    amount: amount(unitAmount),
    currency: clean(currency) || "USD",
    display: null,
});
window.ox.install(1, ({ action, retryFetch, log }) => {
    const graphql = async (operationName, query, variables = {}) => {
        const response = await retryFetch(`${ORIGIN}/graphql/${operationName}?operation=${encodeURIComponent(operationName)}`, {
            method: "POST",
            credentials: "include",
            headers: {
                Accept: "application/json",
                "Content-Type": "application/json",
                "x-channel-id": "marketplace",
                "x-experience-id": "doordash",
            },
            body: JSON.stringify({ operationName, variables, query: clean(query) }),
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
        }
        catch {
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
            rating: Number.isFinite(Number(header.ratings?.averageRating))
                ? Number(header.ratings.averageRating)
                : null,
            ratingCount: Number.isFinite(Number(header.ratings?.numRatings))
                ? Number(header.ratings.numRatings)
                : null,
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
                display: clean(orderItem.priceDisplayString) || null,
            },
            imageUrl: clean(orderItem.item?.imageUrl) || null,
            storeId: String(orderItem.item?.storeId ?? cart.restaurant?.id ?? ""),
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
                url: cart.restaurant?.id
                    ? `${ORIGIN}/store/${encodeURIComponent(String(cart.restaurant.id))}`
                    : null,
            },
            subtotal: cartMoney(cart.subtotal, currency),
            total: cartMoney(cart.total, currency),
            items,
            checkoutUrl: `${ORIGIN}/consumer/checkout/`,
        };
    };
    const fetchOrders = async (limit) => {
        const response = await retryFetch(`${ORIGIN}/orders`, {
            credentials: "include",
            headers: { Accept: "text/html" },
        });
        const html = await response.text();
        if (response.status === 401 || response.status === 403 || /identity\.doordash\.com/.test(response.url)) {
            throw new Error("DoorDash requires sign-in");
        }
        if (!response.ok)
            throw new Error(`DoorDash order history HTTP ${response.status}`);
        const doc = new DOMParser().parseFromString(html, "text/html");
        const cards = [...doc.querySelectorAll('[data-testid="OrderHistoryOrderItem"]')];
        const seen = new Set();
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
                options: (orderItem.optionsList ?? [])
                    .map((option) => clean(option?.itemExtraOption?.name))
                    .filter(Boolean),
                specialInstructions: clean(orderItem.specialInstructions) || null,
                substitutionPreference: clean(orderItem.substitutionPreference) || null,
            };
        }));
        const lineItems = (receipt.lineItems ?? []).map((lineItem) => ({
            label: clean(lineItem.label),
            note: clean(lineItem.note) || null,
            amount: money(lineItem.finalMoney),
            originalAmount: lineItem.originalMoney ? money(lineItem.originalMoney) : null,
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
            items,
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
                state: "/",
            });
            return { url: `https://identity.doordash.com/auth?${query}` };
        },
    });
    action("getSignInState", {
        async invoke() {
            const response = await retryFetch(`${ORIGIN}/unified-gateway/notification_preferences/v1/doordash/consumer`, {
                credentials: "include",
                headers: { Accept: "application/json" },
                redirect: "manual",
            });
            if (response.status === 401 || response.status === 403 || response.status === 302) {
                return { signedIn: false };
            }
            if (!response.ok)
                throw new Error(`DoorDash sign-in probe HTTP ${response.status}`);
            return { signedIn: true };
        },
    });
    action("getStore", {
        async invoke({ storeId } = {}) {
            if (!clean(storeId))
                throw new Error("getStore requires storeId");
            return { store: await fetchStore(clean(storeId)) };
        },
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
                    ...(clean(cursor) ? { cursor: clean(cursor) } : {}),
                },
            });
            const result = data?.retailSearch;
            const seen = new Set();
            const items = [];
            const listedItems = [...(result?.list ?? [])];
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
                            displayString: itemPrice.display_string,
                        },
                        unit: itemData.display_unit || itemData.sold_as_info_short_string,
                        ratings: null,
                        quickAddContext: {
                            isEligible: Boolean(custom?.quantity_stepper),
                            defaultQuantity: 1,
                        },
                    });
                }
                catch {
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
                    rating: Number.isFinite(Number(item.ratings?.averageRating))
                        ? Number(item.ratings.averageRating)
                        : null,
                    ratingCount: Number.isFinite(Number(item.ratings?.numOfRatings))
                        ? Number(item.ratings.numOfRatings)
                        : null,
                    additionalVariants: null,
                    canQuickAdd: Boolean(item.quickAddContext?.isEligible),
                    defaultQuantity: Number(item.quickAddContext?.defaultQuantity ?? 1),
                });
                if (items.length >= requestedLimit)
                    break;
            }
            log(`searchStoreItems store=${clean(storeId)} results=${items.length}`);
            return {
                items,
                nextCursor: result?.pageInfo?.hasNextPage ? clean(result.pageInfo.cursor) || null : null,
            };
        },
    });
    action("getCart", {
        async invoke() {
            return { cart: await fetchCart() };
        },
    });
    action("listOrders", {
        async invoke({ limit = 10 } = {}) {
            const requestedLimit = Math.max(1, Math.min(10, Number(limit) || 10));
            const items = await fetchOrders(requestedLimit);
            return { items, nextCursor: null };
        },
    });
    action("getOrder", {
        async invoke({ orderCartId } = {}) {
            if (!clean(orderCartId))
                throw new Error("getOrder requires orderCartId");
            return { order: await fetchReceipt(clean(orderCartId)) };
        },
    });
    action("getPaymentUrl", {
        async invoke() {
            return { url: `${ORIGIN}/consumer/checkout/` };
        },
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
                    completedAt: null,
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
                        completedAt: null,
                    };
                }
            }
            catch (error) {
                log(`getPaymentState order verification unavailable: ${error instanceof Error ? error.message : String(error)}`);
            }
            return { status: "none", reference: null, total: 0, currency: "USD", completedAt: null };
        },
    });
});
