import type { ActionInstaller } from "@openox/service-sdk/action";
import { cleanText } from "@openox/service-sdk/action-lib";

const BASE = "https://blueprint.bryanjohnson.com";

const absoluteUrl = (value: unknown) => {
  const text = cleanText(value);
  if (!text) return "";
  try {
    return new URL(text, BASE).href;
  } catch {
    return "";
  }
};

const identifier = (value: unknown) => cleanText(value);

const price = (value: unknown) => {
  const number = Number(value);
  return Number.isFinite(number) ? number : 0;
};

const plainText = (value: unknown) => {
  const document = new DOMParser().parseFromString(`<div>${String(value ?? "")}</div>`, "text/html");
  return cleanText(document.body.textContent);
};

const imageUrl = (value: any) => absoluteUrl(value?.url || value?.src || value);

const productSummary = (product: any) => ({
  id: identifier(product?.id),
  handle: cleanText(product?.handle),
  name: cleanText(product?.title),
  description: plainText(product?.body || product?.body_html),
  productUrl: absoluteUrl(product?.url || `/products/${product?.handle ?? ""}`),
  image: imageUrl(product?.featured_image || product?.image || product?.images?.[0]),
  price: price(product?.price ?? product?.price_min ?? product?.variants?.[0]?.price),
  available: Boolean(product?.available ?? product?.variants?.some((variant: any) => variant?.available)),
});

const variant = (value: any) => ({
  id: identifier(value?.id),
  productId: identifier(value?.product_id),
  name: cleanText(value?.title),
  sku: cleanText(value?.sku),
  price: price(value?.price),
  currency: cleanText(value?.price_currency) || "USD",
  available: value?.available === undefined ? null : Boolean(value.available),
  image: imageUrl(value?.featured_image),
  weight: Number.isFinite(Number(value?.weight)) ? Number(value.weight) : null,
  weightUnit: cleanText(value?.weight_unit) || null,
});

const product = (value: any) => ({
  ...productSummary(value),
  variants: (value?.variants ?? []).map(variant).filter((item: any) => item.id),
});

const cartItem = (item: any, currency = "USD") => ({
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
  sellingPlanId: item?.selling_plan_allocation?.selling_plan?.id === undefined
    ? null
    : identifier(item.selling_plan_allocation.selling_plan.id),
});

const install: ActionInstaller = ({ action, retryFetch, log }) => {
  const fetchJson = async (path: string, init?: RequestInit) => {
    const response = await retryFetch(`${BASE}${path}`, { credentials: "include", ...init });
    if (!response.ok) throw new Error(`${path}: HTTP ${response.status}`);
    return response.json();
  };

  action("searchProducts", {
    async invoke({ query, limit = 4 }) {
      const text = cleanText(query);
      if (!text) throw new Error("Search text cannot be empty.");
      const parameters = new URLSearchParams({
        q: text,
        "resources[type]": "product",
        "resources[limit]": String(limit),
        "resources[options][unavailable_products]": "hide",
      });
      const response = await fetchJson(`/search/suggest.json?${parameters}`);
      const items = (response?.resources?.results?.products ?? [])
        .map(productSummary)
        .filter((item: any) => item.id && item.name);
      log(`searchProducts: ${items.length} products`);
      return { items, nextCursor: null };
    },
  });

  action("listFavoriteProducts", {
    async invoke({ limit = 4 }) {
      const response = await fetchJson(`/collections/bryans-favorites/products.json?limit=${limit}`);
      const items = (response?.products ?? []).map(product).filter((item: any) => item.id && item.name);
      log(`listFavoriteProducts: ${items.length} products`);
      return { items, nextCursor: null };
    },
  });

  action("getVariant", {
    async invoke({ id }) {
      const variantId = identifier(id);
      if (!variantId) throw new Error("A variant ID is required.");
      const response = await fetchJson(`/variants/${encodeURIComponent(variantId)}.json`);
      const result = variant(response?.product_variant);
      if (!result.id) throw new Error(`Variant ${variantId} was not found.`);
      return result;
    },
  });

  action("getCart", {
    async invoke() {
      const response = await fetchJson("/cart.js");
      const currency = cleanText(response?.currency) || "USD";
      return {
        items: (response?.items ?? []).map((item: any) => cartItem(item, currency)),
        itemCount: Number(response?.item_count ?? 0),
        subtotal: price(response?.items_subtotal_price) / 100,
        total: price(response?.total_price) / 100,
        currency,
      };
    },
  });

  action("addCartItem", {
    async invoke({ variantId, quantity, sellingPlanId }) {
      const item: Record<string, number> = {
        id: Number(variantId),
        quantity,
      };
      if (sellingPlanId) item.selling_plan = Number(sellingPlanId);
      const response = await fetchJson("/cart/add.js", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          items: [item],
          sections: ["cart-icon-bubble", "mobile-cart-icon-bubble", "cart-drawer"],
        }),
      });
      const added = response?.items?.[0];
      if (!added) throw new Error("Blueprint did not return the added cart item.");
      log(`addCartItem: variant ${variantId}, quantity ${quantity}`);
      return cartItem(added);
    },
  });
};

export default install;
