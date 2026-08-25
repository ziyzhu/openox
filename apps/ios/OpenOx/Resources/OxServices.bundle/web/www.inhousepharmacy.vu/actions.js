window.ox.install(1, ({ action, retryFetch, log, lib }) => {
    const { cleanText } = lib;
    const BASE = "https://www.inhousepharmacy.vu";
    const absoluteUrl = (value) => {
        if (!value)
            return "";
        try {
            return new URL(value, BASE).toString();
        }
        catch {
            return "";
        }
    };
    const money = (value) => {
        const match = cleanText(value).match(/-?\s*[$€£]?\s*([\d,]+(?:\.\d+)?)/);
        return match ? Number(match[1].replace(/,/g, "")) : 0;
    };
    const currency = (value) => {
        const text = cleanText(value);
        const code = text.match(/\b(USD|AUD|EUR|GBP|HKD|SGD)\b/i)?.[1];
        if (code)
            return code.toUpperCase();
        if (text.includes("€"))
            return "EUR";
        if (text.includes("£"))
            return "GBP";
        return "USD";
    };
    const productIdFrom = (value) => cleanText(value).match(/\/p-(\d+)-/i)?.[1] ?? null;
    const fetchDoc = async (path) => {
        const url = path.startsWith("http") ? path : BASE + path;
        const response = await retryFetch(url, { credentials: "include" });
        if (!response.ok)
            throw new Error(`Inhouse Pharmacy returned HTTP ${response.status}.`);
        const doc = new DOMParser().parseFromString(await response.text(), "text/html");
        return { doc, url: response.url };
    };
    const productUrl = (input) => {
        const url = new URL(input, BASE);
        if (url.hostname !== "www.inhousepharmacy.vu" || !productIdFrom(url.pathname)) {
            throw new Error("Use an Inhouse Pharmacy product URL from search results.");
        }
        return url.toString();
    };
    const valueAfterBold = (root, label) => {
        for (const bold of root.querySelectorAll("b")) {
            if (cleanText(bold.textContent).replace(/:$/, "").toLowerCase() !== label.toLowerCase())
                continue;
            return cleanText(bold.nextSibling?.textContent);
        }
        return "";
    };
    const detailValue = (doc, label) => {
        for (const detail of doc.querySelectorAll(".pdetail")) {
            const heading = cleanText(detail.querySelector(".leftPName1")?.textContent);
            if (heading.toLowerCase() !== label.toLowerCase())
                continue;
            const value = detail.cloneNode(true);
            value.querySelector(".leftPName1")?.remove();
            for (const br of value.querySelectorAll("br"))
                br.replaceWith(" ");
            return cleanText(value.textContent);
        }
        return "";
    };
    const parseCart = (doc) => {
        const items = [...doc.querySelectorAll(".cart-items .item")].map((item) => {
            const link = item.querySelector(".item-name a");
            const url = absoluteUrl(link?.getAttribute("href"));
            const subtotalText = cleanText(item.querySelector(".item-subtotal")?.textContent);
            return {
                productId: productIdFrom(url) ?? "",
                name: cleanText(link?.textContent),
                url,
                quantity: Number(cleanText(item.querySelector(".item-qty")?.textContent)) || 0,
                subtotal: money(subtotalText),
            };
        }).filter((item) => item.productId && item.name);
        const totalText = cleanText(doc.querySelector("#ctl00_PageContent_ctl00_ctrlCartSummary_lblTotal")?.textContent);
        return {
            items,
            total: items.length ? money(totalText) : 0,
            currency: currency(totalText),
        };
    };
    const fetchCart = async () => parseCart((await fetchDoc("/shoppingcart.aspx")).doc);
    const parseOrder = (card) => {
        const receiptLink = card.querySelector(".order-number a[href*='receipt.aspx']");
        const receiptUrl = absoluteUrl(receiptLink?.getAttribute("href"));
        const id = new URL(receiptUrl || BASE).searchParams.get("ordernumber") ?? "";
        const totalText = cleanText(card.querySelector(".order-total .price")?.textContent);
        const trackingLink = card.querySelector(".order-shipping a");
        const products = [...card.querySelectorAll(".order-products .order-item-content > div")].map((item) => {
            const text = cleanText(item.textContent);
            const match = text.match(/^(\d+)\s*x\s*(.+)$/i);
            const link = item.querySelector("a");
            return {
                quantity: match ? Number(match[1]) : 1,
                name: cleanText(link?.textContent) || match?.[2] || text,
                productUrl: absoluteUrl(link?.getAttribute("href")),
            };
        }).filter((item) => item.name);
        return {
            id,
            reference: cleanText(receiptLink?.textContent).replace(/^Order\s*#\s*/i, ""),
            date: cleanText(card.querySelector(".order-date")?.textContent),
            paymentMethod: cleanText(card.querySelector(".payment-method")?.textContent),
            paymentStatus: cleanText(card.querySelector(".payment-status")?.textContent),
            shippingStatus: cleanText(card.querySelector(".order-shipping .order-item-content")?.textContent),
            trackingNumber: cleanText(trackingLink?.textContent) || null,
            trackingUrl: absoluteUrl(trackingLink?.getAttribute("href")) || null,
            products,
            total: money(totalText),
            currency: currency(totalText),
        };
    };
    const fetchOrders = async () => {
        const { doc, url } = await fetchDoc("/account.aspx?order-history");
        if (new URL(url, BASE).pathname.toLowerCase().includes("signin.aspx")) {
            throw new Error("Sign in to Inhouse Pharmacy to read orders.");
        }
        return [...doc.querySelectorAll(".order-list .order-item")]
            .map(parseOrder)
            .filter((order) => order.id && order.reference);
    };
    const receiptValue = (doc, label) => {
        for (const row of doc.querySelectorAll("#tblOrderInfo tr")) {
            const cells = row.querySelectorAll("td");
            for (let index = 0; index + 1 < cells.length; index += 2) {
                if (cleanText(cells[index]?.textContent).replace(/:$/, "").toLowerCase() === label.toLowerCase()) {
                    return cleanText(cells[index + 1]?.textContent);
                }
            }
        }
        return "";
    };
    const receiptTotal = (doc) => {
        for (const row of doc.querySelectorAll("#tblOrderSummary tr")) {
            const label = cleanText(row.querySelector(".tdOrderSummaryLabel")?.textContent).replace(/:$/, "");
            if (label.toLowerCase() === "total")
                return cleanText(row.querySelector(".tdOrderSummaryValue")?.textContent);
        }
        return "";
    };
    action("getSignInUrl", {
        async invoke() {
            return { url: BASE + "/signin.aspx?returnurl=account.aspx%3forder-history" };
        },
    });
    action("getSignInState", {
        async invoke() {
            const { doc, url } = await fetchDoc("/account.aspx?order-history");
            const signedIn = !new URL(url, BASE).pathname.toLowerCase().includes("signin.aspx")
                && !!doc.querySelector(".acct-link-signout");
            log(`getSignInState: signedIn=${signedIn}`);
            return { signedIn };
        },
    });
    action("searchProducts", {
        async invoke({ query }) {
            const search = cleanText(query);
            if (search.length < 3)
                throw new Error("Search with at least three characters.");
            const { doc } = await fetchDoc(`/search.aspx?searchterm=${encodeURIComponent(search)}`);
            const items = [...doc.querySelectorAll(".search_results")].map((card) => {
                const link = card.querySelector(".search_text a[href*='/p-'], .search_img a[href*='/p-']");
                const url = absoluteUrl(link?.getAttribute("href"));
                return {
                    productId: productIdFrom(url) ?? "",
                    name: cleanText(card.querySelector(".search_text a")?.textContent),
                    url,
                    imageUrl: absoluteUrl(card.querySelector(".search_img img")?.getAttribute("src")),
                    activeIngredient: valueAfterBold(card, "Active Ingredient") || null,
                    description: valueAfterBold(card, "Description") || null,
                    manufacturer: valueAfterBold(card, "Manufacturer") || null,
                };
            }).filter((item) => item.productId && item.name);
            log(`searchProducts: ${items.length} results for ${search}`);
            return { items, nextCursor: null };
        },
    });
    action("getProduct", {
        async invoke({ url }) {
            const requestedUrl = productUrl(url);
            const { doc } = await fetchDoc(requestedUrl);
            const canonicalUrl = absoluteUrl(doc.querySelector("link[rel='canonical']")?.getAttribute("href")) || requestedUrl;
            const id = productIdFrom(canonicalUrl);
            const name = detailValue(doc, "Product Name");
            if (!id || !name)
                throw new Error("The product page did not contain product details.");
            const offers = [...doc.querySelectorAll("[itemprop='offers']")].map((offer) => {
                const variant = offer.querySelector("input[name^='VariantID_']");
                const priceElement = offer.querySelector(".prod_variant_price [itemprop='price'], .prod_variant_price .price-new, .prod_variant_price .price-from");
                const priceText = cleanText(priceElement?.textContent);
                return {
                    variantId: cleanText(variant?.getAttribute("value")),
                    title: cleanText(offer.querySelector("[itemprop='itemOffered']")?.textContent),
                    price: money(priceElement?.getAttribute("content") || priceText),
                    currency: currency(offer.querySelector("[itemprop='priceCurrency']")?.getAttribute("content") || priceText),
                    inStock: !!offer.querySelector("input.AddToCartButton, input.btn-add-cart")
                        && !offer.querySelector(".btn-out-of-stock"),
                };
            }).filter((offer) => offer.variantId && offer.title);
            return {
                productId: id,
                name,
                url: canonicalUrl,
                imageUrl: absoluteUrl(doc.querySelector("meta[property='og:image']")?.getAttribute("content")),
                activeIngredient: detailValue(doc, "Active Ingredient") || null,
                manufacturer: detailValue(doc, "Manufacturer") || null,
                productType: detailValue(doc, "Product Type") || null,
                expiryDate: detailValue(doc, "Product expiry date we are currently shipping") || null,
                description: cleanText(doc.querySelector("#desc [itemprop='description']")?.textContent) || null,
                offers,
            };
        },
    });
    action("getCart", {
        async invoke() {
            const cart = await fetchCart();
            log(`getCart: ${cart.items.length} items, ${cart.total} ${cart.currency}`);
            return cart;
        },
    });
    action("addCartItem", {
        async invoke({ url, variantId, quantity = 1 }) {
            if (!Number.isInteger(quantity) || quantity < 1 || quantity > 20) {
                throw new Error("Quantity must be a whole number from 1 through 20.");
            }
            const requestedUrl = productUrl(url);
            const { doc } = await fetchDoc(requestedUrl);
            const productId = productIdFrom(requestedUrl);
            const variant = doc.querySelector(`input[name^='VariantID_'][value='${CSS.escape(String(variantId))}']`);
            const offer = variant?.closest("[itemprop='offers']");
            if (!productId || !variant || !offer?.querySelector("input.AddToCartButton, input.btn-add-cart")) {
                throw new Error("That product option is not available to add to the cart.");
            }
            const form = doc.querySelector("form#aspnetForm");
            if (!form)
                throw new Error("The product form is unavailable.");
            const body = new URLSearchParams();
            for (const input of form.querySelectorAll("input[name]")) {
                const type = cleanText(input.getAttribute("type")).toLowerCase();
                if (["button", "submit", "image", "file", "password"].includes(type))
                    continue;
                if (["checkbox", "radio"].includes(type) && !input.hasAttribute("checked"))
                    continue;
                body.append(input.getAttribute("name"), input.getAttribute("value") ?? "");
            }
            body.set("__EVENTTARGET", "AddToCart");
            body.set("__EVENTARGUMENT", `0_${productId}_${variantId}`);
            body.set(`Quantity_${productId}_${variantId}`, String(quantity));
            const actionUrl = absoluteUrl(form.getAttribute("action")) || requestedUrl;
            const response = await retryFetch(actionUrl, {
                method: "POST",
                credentials: "include",
                headers: { "content-type": "application/x-www-form-urlencoded" },
                body: body.toString(),
            });
            if (!response.ok)
                throw new Error(`Cart update returned HTTP ${response.status}.`);
            await response.text();
            const cart = await fetchCart();
            if (!cart.items.some((item) => item.productId === productId)) {
                throw new Error("The cart did not retain the selected product.");
            }
            log(`addCartItem: product=${productId} variant=${variantId} quantity=${quantity}`);
            return cart;
        },
    });
    action("listOrders", {
        async invoke() {
            const items = await fetchOrders();
            log(`listOrders: ${items.length} orders`);
            return { items, nextCursor: null };
        },
    });
    action("getOrder", {
        async invoke({ id }) {
            const normalizedId = cleanText(id).replace(/-IPV$/i, "");
            if (!/^\d+$/.test(normalizedId))
                throw new Error("Use an order ID from the order list.");
            const orders = await fetchOrders();
            const summary = orders.find((order) => order.id === normalizedId);
            if (!summary)
                throw new Error(`Order ${id} was not found in the signed-in account.`);
            const { doc, url } = await fetchDoc(`/receipt.aspx?ordernumber=${encodeURIComponent(normalizedId)}`);
            if (new URL(url, BASE).pathname.toLowerCase().includes("signin.aspx")) {
                throw new Error("Sign in to Inhouse Pharmacy to read this order.");
            }
            const headerRows = [...doc.querySelectorAll("#tblOrderHeader tr")];
            const reference = cleanText(headerRows[0]?.querySelector(".tdOrderHeaderValue")?.textContent) || summary.reference;
            const date = cleanText(headerRows[1]?.querySelector(".tdOrderHeaderValue")?.textContent) || summary.date;
            const items = [...doc.querySelectorAll("#tblLineItems tr")].map((row) => {
                const name = cleanText(row.querySelector("#lblProductName")?.textContent);
                return {
                    name,
                    quantity: Number(cleanText(row.querySelector("#colQuantity")?.textContent)) || 0,
                    unitPrice: money(row.querySelector("#colPrice")?.textContent),
                    total: money(row.querySelector("#colExtPrice")?.textContent),
                };
            }).filter((item) => item.name);
            if (!items.length)
                throw new Error(`Order ${id} did not contain receipt items.`);
            const totalText = receiptTotal(doc);
            return {
                id: normalizedId,
                reference,
                date,
                currency: currency(receiptValue(doc, "Locale/Currency") || totalText),
                paymentMethod: receiptValue(doc, "Payment Method") || summary.paymentMethod,
                paymentStatus: summary.paymentStatus,
                shippingStatus: summary.shippingStatus,
                trackingNumber: summary.trackingNumber,
                trackingUrl: summary.trackingUrl,
                items,
                total: money(totalText) || summary.total,
            };
        },
    });
    action("getPaymentUrl", {
        async invoke() {
            return { url: BASE + "/shoppingcart.aspx" };
        },
    });
    action("getPaymentState", {
        async invoke({ since, previousOrderId } = {}) {
            const liveId = location.pathname.toLowerCase().endsWith("/receipt.aspx")
                ? new URL(location.href).searchParams.get("ordernumber")
                : null;
            if (liveId) {
                const totalText = receiptTotal(document);
                const reference = cleanText([...document.querySelectorAll("#tblOrderHeader .tdOrderHeaderValue")][0]?.textContent) || liveId;
                return {
                    status: "completed",
                    reference,
                    total: money(totalText),
                    currency: currency(totalText),
                    completedAt: cleanText([...document.querySelectorAll("#tblOrderHeader .tdOrderHeaderValue")][1]?.textContent) || null,
                };
            }
            const cart = await fetchCart();
            if (cart.items.length) {
                return {
                    status: "pending",
                    reference: null,
                    total: cart.total,
                    currency: cart.currency,
                    completedAt: null,
                };
            }
            try {
                const orders = await fetchOrders();
                const candidate = previousOrderId
                    ? orders.find((order) => order.id !== cleanText(previousOrderId).replace(/-IPV$/i, ""))
                    : undefined;
                const sinceDay = since?.slice(0, 10);
                const candidateDay = candidate?.date ? new Date(candidate.date).toISOString().slice(0, 10) : null;
                if (candidate && (!sinceDay || candidateDay === sinceDay || candidateDay > sinceDay)) {
                    return {
                        status: "completed",
                        reference: candidate.reference,
                        total: candidate.total,
                        currency: candidate.currency,
                        completedAt: candidate.date,
                    };
                }
            }
            catch (error) {
                log(`getPaymentState: order verification unavailable: ${error instanceof Error ? error.message : String(error)}`);
            }
            return { status: "none", reference: null, total: 0, currency: "USD", completedAt: null };
        },
    });
});
