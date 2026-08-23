import type { ActionInstaller } from "../action.ts";
import { cleanText, pageCursor } from "../../../action-lib.ts";

const BASE = "https://www.skinceuticals.com";
const STORE = "/on/demandware.store/Sites-skinc-us-Site/en_US";

const absoluteUrl = (value: unknown) => {
  const text = cleanText(value);
  if (!text) return "";
  try {
    return new URL(text, BASE).href;
  } catch {
    return "";
  }
};

const money = (value: unknown) => {
  const match = cleanText(value).replace(/,/g, "").match(/-?\d+(?:\.\d+)?/);
  return match ? Number(match[0]) : 0;
};

const nullableNumber = (value: unknown) => {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
};

const jsonAttribute = (element: Element | null, name: string) => {
  const value = element?.getAttribute(name);
  if (!value) return null;
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
};

const jsonScripts = (document: Document) =>
  [...document.querySelectorAll<HTMLScriptElement>('script[type="application/ld+json"]')]
    .flatMap((script) => {
      try {
        return [JSON.parse(script.textContent ?? "")];
      } catch {
        return [];
      }
    });

const schemaType = (value: unknown, type: string) => {
  const candidate = value as { "@type"?: string | string[] } | null;
  const types = Array.isArray(candidate?.["@type"])
    ? candidate["@type"]
    : [candidate?.["@type"]];
  return types.includes(type);
};

const idFromUrl = (value: unknown) => {
  try {
    const segment = new URL(String(value), BASE).pathname.split("/").filter(Boolean).at(-1) ?? "";
    return decodeURIComponent(segment.replace(/\.html$/i, ""));
  } catch {
    return "";
  }
};

const availability = (value: unknown) => cleanText(value).split("/").at(-1) === "InStock";

const productSummary = (entry: any) => {
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
    reviewCount: nullableNumber(rating?.reviewCount),
  };
};

const nextCursor = (document: Document) => {
  const href = document.querySelector<HTMLAnchorElement>("[data-js-load-more], .c-pagination__item.m-number")?.href;
  if (!href) return null;
  try {
    return new URL(href, BASE).searchParams.get("start");
  } catch {
    return null;
  }
};

const orderDate = (value: string) => {
  const match = value.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
  if (!match) return value;
  return `${match[3]}-${match[1]!.padStart(2, "0")}-${match[2]!.padStart(2, "0")}`;
};

const parseOrders = (document: Document) => {
  const items = [...document.querySelectorAll<HTMLElement>(".c-account-table__row[data-js-row-item]")].map((row) => {
    const cell = (suffix: string) => cleanText(row.querySelector(`.c-account-table__cell.${suffix} .c-account-table__cell-value`)?.textContent);
    const detailUrl = absoluteUrl(row.querySelector<HTMLAnchorElement>('a[href*="Order-Details"]')?.href);
    const id = detailUrl ? new URL(detailUrl).searchParams.get("orderNumber") ?? "" : "";
    const trackingNumbers = [...row.querySelectorAll(".c-account-table__cell.m-ship-number li")]
      .map((element) => cleanText(element.textContent).replace(/-\s*Track Shipment$/i, ""))
      .filter((value) => value && value !== "-");
    return {
      id,
      date: orderDate(cell("m-date")),
      status: cell("m-status"),
      total: money(cell("m-total")),
      currency: "USD",
      shippingMethod: cell("m-ship-option"),
      trackingNumbers,
      detailUrl,
    };
  }).filter((item) => item.id);
  return { items, nextCursor: nextCursor(document) };
};

type CartItem = {
  lineItemId: string;
  id: string;
  sku: string;
  name: string;
  description: string;
  size: string;
  quantity: number;
  unitPrice: number;
  total: number;
  currency: string;
  image: string;
  productUrl: string;
};

const parseCart = (document: Document) => {
  const form = document.querySelector<HTMLFormElement>("#cartitems");
  const items: CartItem[] = [...document.querySelectorAll<HTMLElement>('.c-product-table__row.m-row-1[data-lora-datalayer]')]
    .flatMap((row) => {
      const lineItems = jsonAttribute(row, "data-lora-datalayer")?.lineitems;
      const pair = Object.entries(lineItems ?? {})[0] as [string, any] | undefined;
      if (!pair) return [];
      const [lineItemId, lineItem] = pair;
      const product = lineItem?.product ?? {};
      const quantityInput = form?.querySelector<HTMLInputElement>(`[name="item_quantity_${CSS.escape(lineItemId)}"]`);
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
        productUrl: absoluteUrl(product.url),
      }];
    });
  const totalRows = [...document.querySelectorAll<HTMLElement>("#cart-totals .c-cart-summary-table__item")];
  const totalValue = (label: RegExp) => {
    const row = totalRows.find((candidate) => label.test(cleanText(candidate.querySelector(".m-label")?.textContent)));
    return row ? money(row.querySelector(".m-value")?.textContent) : 0;
  };
  const subtotal = totalValue(/^Subtotal$/i) || items.reduce((sum, item) => sum + item.total, 0);
  const total = totalValue(/Estimated Total/i) || subtotal;
  return { items, subtotal, total, currency: items[0]?.currency ?? "USD" };
};

const install: ActionInstaller = ({ action, retryFetch, log }) => {
  const fetchDocument = async (url: string) => {
    const response = await retryFetch(url, { credentials: "include" });
    if (!response.ok) throw new Error(`${new URL(url, BASE).pathname}: HTTP ${response.status}`);
    const document = new DOMParser().parseFromString(await response.text(), "text/html");
    const title = cleanText(document.title).toLowerCase();
    if (title.includes("just a moment") || title.includes("attention required")) {
      throw new Error("SkinCeuticals requires a browser check. Open the service, complete it, and retry.");
    }
    return document;
  };

  const fetchCart = async () => parseCart(await fetchDocument(`${BASE}${STORE}/Cart-Show`));

  const fetchOrderHistory = async (cursor = 0, limit = 10) => {
    const parameters = new URLSearchParams({
      start: String(cursor),
      sz: String(limit),
      sort: "date",
      order: "DESC",
    });
    const document = await fetchDocument(`${BASE}${STORE}/Order-History?${parameters}`);
    const signedIn = Boolean(document.querySelector('a[href*="Account-Logout"]'));
    if (!signedIn) throw new Error("Sign in to SkinCeuticals to read order history.");
    return { document, ...parseOrders(document) };
  };

  action("getSignInUrl", {
    async invoke() {
      return { url: `${BASE}/account` };
    },
  });

  action("getSignInState", {
    async invoke() {
      const document = await fetchDocument(`${BASE}${STORE}/Account-Profile`);
      return { signedIn: Boolean(document.querySelector('a[href*="Account-Logout"]')) };
    },
  });

  action("searchProducts", {
    async invoke({ query, cursor, limit = 10, sort = "relevance" }) {
      const text = cleanText(query);
      if (!text) throw new Error("Search text cannot be empty.");
      const start = pageCursor(cursor, 0);
      const sortRules: Record<string, string> = {
        relevance: "best-matches",
        best_sellers: "best-sellers-revenue",
        newest: "newest-first",
        price_low: "price-ascending",
        price_high: "price-descending",
        top_rated: "top-rated",
      };
      const parameters = new URLSearchParams({
        q: text,
        start: String(start),
        sz: String(limit),
        prefn1: "b2bProductFlag",
        prefv1: "false",
        srule: sortRules[sort] ?? sortRules.relevance,
      });
      const document = await fetchDocument(`${BASE}${STORE}/Search-Show?${parameters}`);
      const list = jsonScripts(document).find((value) => schemaType(value, "ItemList"));
      const items = (list?.itemListElement ?? []).map(productSummary).filter((item: any) => item.id && item.name);
      log(`searchProducts offset ${start}: ${items.length} products`);
      return { items, nextCursor: nextCursor(document) };
    },
  });

  action("getProduct", {
    async invoke({ id }) {
      const productId = cleanText(id);
      if (!productId) throw new Error("A product ID or SKU is required.");
      const document = await fetchDocument(`${BASE}${STORE}/Product-Show?pid=${encodeURIComponent(productId)}`);
      const structured = jsonScripts(document);
      const product = structured.find((value) => schemaType(value, "ProductGroup"))
        ?? structured.find((value) => schemaType(value, "Product"));
      if (!product) throw new Error(`Product ${productId} was not found.`);
      const pageData = jsonAttribute(document.body, "data-lora-datalayer")?.product ?? {};
      const rawVariants = schemaType(product, "ProductGroup") ? product.hasVariant ?? [] : [product];
      const variants = rawVariants.map((variant: any) => {
        const offer = Array.isArray(variant.offers) ? variant.offers[0] : variant.offers;
        return {
          sku: cleanText(variant.sku),
          size: cleanText(variant.size),
          price: nullableNumber(offer?.price),
          currency: cleanText(offer?.priceCurrency) || null,
          available: availability(offer?.availability),
          productUrl: absoluteUrl(variant.url || variant["@id"]),
          image: absoluteUrl(Array.isArray(variant.image) ? variant.image[0] : variant.image),
        };
      }).filter((variant: any) => variant.sku);
      const canonical = absoluteUrl(document.querySelector<HTMLLinkElement>('link[rel="canonical"]')?.href);
      const rating = product.aggregateRating;
      const result = {
        id: cleanText(product.productGroupID || product.sku) || idFromUrl(canonical),
        name: cleanText(product.name || pageData.title),
        description: cleanText(pageData.description || product.description || document.querySelector('meta[name="description"]')?.getAttribute("content")),
        productUrl: canonical,
        image: absoluteUrl(pageData.imgUrl || (Array.isArray(product.image) ? product.image[0] : product.image)),
        ratingValue: nullableNumber(rating?.ratingValue),
        reviewCount: nullableNumber(rating?.reviewCount),
        variants,
      };
      if (!result.id || !result.name || !result.variants.length) throw new Error(`Product ${productId} returned incomplete details.`);
      return result;
    },
  });

  action("getCart", {
    async invoke() {
      return fetchCart();
    },
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
          [`item_quantity_${existing.lineItemId}`]: String(existing.quantity),
        });
        if (quantity === 0) body.set("item_remove", existing.lineItemId);
        else body.set(`item_quantity_${existing.lineItemId}`, String(quantity));
        const response = await retryFetch(`${BASE}${STORE}/Cart-Submit?ajax=true`, {
          method: "POST",
          credentials: "include",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: body.toString(),
        });
        if (!response.ok) throw new Error(`Cart update: HTTP ${response.status}`);
        await response.text();
      } else if (quantity > 0) {
        const response = await retryFetch(`${BASE}${STORE}/Cart-AddProduct?ajax=true`, {
          method: "POST",
          credentials: "include",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: new URLSearchParams({ pid: sku, quantity: String(quantity), placement: "ox" }).toString(),
        });
        if (!response.ok) throw new Error(`Add to cart: HTTP ${response.status}`);
        const result = await response.json();
        if (!result?.uuid) throw new Error(cleanText(result?.text?.errorMessage || "SkinCeuticals rejected the cart update."));
      }
      const cart = await fetchCart();
      const updated = cart.items.find((item) => item.sku === sku);
      if ((quantity === 0 && updated) || (quantity > 0 && updated?.quantity !== quantity)) {
        throw new Error("The cart did not retain the requested quantity.");
      }
      log(`updateCartItem: ${cart.items.length} cart lines, ${cart.total} ${cart.currency}`);
      return cart;
    },
  });

  action("listOrders", {
    async invoke({ cursor, limit = 10 } = {}) {
      const start = pageCursor(cursor, 0);
      const { items, nextCursor } = await fetchOrderHistory(start, limit);
      log(`listOrders offset ${start}: ${items.length} orders`);
      return { items, nextCursor };
    },
  });

  action("getPaymentUrl", {
    async invoke() {
      return { url: `${BASE}${STORE}/Cart-Show` };
    },
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
      const confirmationReference = /Order-(?:Confirm|Confirmation)/i.test(location.pathname)
        ? new URL(location.href).searchParams.get("orderNumber")
          ?? cleanText(document.body?.textContent).match(/\bSKC_\d+\b/)?.[0]
          ?? null
        : null;
      try {
        const { items } = await fetchOrderHistory(0, 10);
        const candidate = confirmationReference
          ? items.find((order) => order.id === confirmationReference)
          : previousOrderId
            ? items.find((order) => order.id !== previousOrderId)
            : undefined;
        const sinceDate = since?.slice(0, 10);
        if (candidate && (!sinceDate || candidate.date >= sinceDate)) {
          return {
            status: "completed",
            reference: candidate.id,
            total: candidate.total,
            currency: candidate.currency,
            completedAt: candidate.date,
          };
        }
      } catch (error) {
        log(`getPaymentState order verification unavailable: ${error instanceof Error ? error.message : String(error)}`);
      }
      return { status: "none", reference: null, total: 0, currency: "USD", completedAt: null };
    },
  });
};

export default install;
