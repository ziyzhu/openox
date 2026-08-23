import type { ActionInstaller } from "../action.ts";
import { operationBaselines } from "./operations.ts";

type JsonObject = Record<string, any>;
type OperationName = keyof typeof operationBaselines;

const clone = <T>(value: T): T => JSON.parse(JSON.stringify(value));

const objects = function* (value: any): Generator<JsonObject> {
  if (!value || typeof value !== "object") return;
  if (Array.isArray(value)) {
    for (const item of value) yield* objects(item);
    return;
  }
  yield value;
  for (const item of Object.values(value)) yield* objects(item);
};

const text = (...values: any[]): string => {
  for (const value of values) if (typeof value === "string" && value) return value;
  return "";
};

const number = (...values: any[]): number => {
  for (const value of values) {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return 0;
};

const firstImage = (value: any): string | null => {
  if (!value || typeof value !== "object") return null;
  for (const candidate of objects(value)) {
    const uri = text(
      candidate.large_share_image?.uri,
      candidate.image?.uri,
      candidate.default_image?.uri,
      candidate.media_image?.uri,
      candidate.square_media_image?.uri,
    );
    if (uri) return uri;
  }
  return null;
};

const nextCursor = (payloads: JsonObject[], preferred?: any): string | null => {
  if (preferred?.page_info) {
    return preferred.page_info.has_next_page ? text(preferred.page_info.end_cursor) || null : null;
  }
  let cursor: string | null = null;
  for (const payload of payloads) {
    for (const candidate of objects(payload)) {
      if (!candidate.page_info || typeof candidate.page_info !== "object") continue;
      cursor = candidate.page_info.has_next_page ? text(candidate.page_info.end_cursor) || null : null;
    }
  }
  return cursor;
};

const groupPosts = (payloads: JsonObject[]): any[] => {
  const byId = new Map<string, any>();
  for (const payload of payloads) {
    for (const candidate of objects(payload)) {
      const content = candidate.comet_sections?.content?.story;
      const story = content || candidate;
      const id = text(story.post_id, candidate.post_id);
      if (!id) continue;
      const context = candidate.comet_sections?.context_layout?.story;
      const timestamp = candidate.comet_sections?.timestamp?.story;
      const actors = story.actors || candidate.actors || context?.actors || [];
      const message = text(
        story.message?.text,
        story.comet_sections?.message?.story?.message?.text,
        story.comet_sections?.message_container?.story?.message?.text,
        candidate.message?.text,
      );
      const current = byId.get(id) || {
        id,
        author: "",
        message: "",
        createdAt: 0,
        url: "",
        imageUrl: null,
      };
      current.author ||= text(actors[0]?.name);
      if (message.length > current.message.length) current.message = message;
      current.createdAt ||= number(candidate.creation_time, story.creation_time, timestamp?.creation_time);
      current.url ||= text(story.wwwURL, story.url, candidate.wwwURL, candidate.url, timestamp?.url);
      current.imageUrl ||= firstImage(story.attachments || candidate.attachments);
      byId.set(id, current);
    }
  }
  return [...byId.values()];
};

const friendSuggestions = (payloads: JsonObject[]): any[] => {
  const byId = new Map<string, any>();
  for (const payload of payloads) {
    for (const candidate of objects(payload)) {
      if (typeof candidate.friendship_status !== "string") continue;
      const id = text(candidate.id);
      const name = text(candidate.name);
      if (!id || !name) continue;
      byId.set(id, {
        id,
        name,
        mutualContext: text(candidate.social_context?.text),
        profilePictureUrl: text(candidate.profile_picture?.uri),
        url: `https://www.facebook.com/profile.php?id=${encodeURIComponent(id)}`,
      });
    }
  }
  return [...byId.values()];
};

const marketplaceListings = (payloads: JsonObject[]): any[] => {
  const byId = new Map<string, any>();
  for (const payload of payloads) {
    for (const candidate of objects(payload)) {
      const listing = candidate.listing || candidate.entity || candidate;
      const title = text(listing.marketplace_listing_title, candidate.data?.title);
      const id = text(listing.id, candidate.entity_id, candidate.data?.product_item_id);
      if (!id || !title) continue;
      const place = listing.location?.reverse_geocode || candidate.entity?.location?.reverse_geocode || {};
      const city = text(place.city_page?.display_name, place.city);
      const state = text(place.state);
      const rawPrice = text(
        listing.formatted_price?.text,
        listing.listing_price?.formatted_amount,
        listing.listing_price?.amount_with_offset_in_currency,
        listing.listing_price?.amount,
        candidate.data?.price?.amount_with_offset,
      );
      const currency = text(candidate.data?.price?.currency);
      byId.set(id, {
        id,
        title,
        price: currency && rawPrice && !rawPrice.includes(currency) ? `${rawPrice} ${currency}` : rawPrice,
        location: [city, state].filter(Boolean).join(", "),
        sellerName: text(listing.marketplace_listing_seller?.name),
        createdAt: number(listing.creation_time),
        imageUrl: firstImage(listing.primary_listing_photo || candidate.photo),
        url: `https://www.facebook.com/marketplace/item/${encodeURIComponent(id)}/`,
      });
    }
  }
  return [...byId.values()];
};

const install: ActionInstaller = ({ action, retryFetch, log }) => {
  const docIds = Object.fromEntries(
    Object.entries(operationBaselines).map(([name, baseline]) => [name, baseline.docId]),
  ) as Record<OperationName, string>;

  const moduleToken = (name: string): string => {
    try {
      const loader = (window as any).require;
      const value = typeof loader === "function" ? loader(name) : null;
      return text(value?.token, value?.initialToken);
    } catch {
      return "";
    }
  };

  const token = (name: string, modules: string[]): string => {
    const input = document.querySelector(`input[name="${name}"]`) as HTMLInputElement | null;
    if (input?.value) return input.value;
    for (const module of modules) {
      const value = moduleToken(module);
      if (value) return value;
    }
    return "";
  };

  const refreshDocId = async (operation: OperationName): Promise<boolean> => {
    const urls = new Set<string>();
    for (const script of document.querySelectorAll("script[src]")) urls.add((script as HTMLScriptElement).src);
    for (const resource of performance.getEntriesByType("resource") as PerformanceResourceTiming[]) {
      if (/\.js(?:\?|$)/.test(resource.name)) urls.add(resource.name);
    }
    const escaped = operation.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const marker = new RegExp(`name:\\\\?"${escaped}\\\\?"`);
    for (const url of urls) {
      let source = "";
      try {
        source = await (await fetch(url, { credentials: "include" })).text();
      } catch {
        continue;
      }
      const match = marker.exec(source);
      if (!match) continue;
      const prefix = source.slice(Math.max(0, match.index - 3000), match.index);
      const ids = [...prefix.matchAll(/(?:id|doc_id):\\?"([0-9]+)\\?"/g)];
      const id = ids.at(-1)?.[1];
      if (!id) continue;
      docIds[operation] = id;
      log(`Facebook refreshed ${operation}`);
      return true;
    }
    return false;
  };

  const request = async (operation: OperationName, variables: JsonObject): Promise<JsonObject[]> => {
    const invoke = async (): Promise<{ response: Response; payloads: JsonObject[] }> => {
      const dtsg = token("fb_dtsg", ["DTSGInitialData", "DTSG"]);
      const lsd = token("lsd", ["LSD"]);
      if (!dtsg || !lsd) throw new Error("Facebook sign-in is required");
      const body = new URLSearchParams({
        __a: "1",
        __comet_req: "15",
        fb_dtsg: dtsg,
        jazoest: `2${[...dtsg].map((character) => character.charCodeAt(0)).join("")}`,
        lsd,
        fb_api_caller_class: "RelayModern",
        fb_api_req_friendly_name: operation,
        variables: JSON.stringify(variables),
        server_timestamps: "true",
        doc_id: docIds[operation],
      });
      const response = await retryFetch("/api/graphql/", {
        method: "POST",
        credentials: "include",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: body.toString(),
      });
      const source = (await response.text()).replace(/^for\s*\(;;\);/, "").trim();
      const payloads: JsonObject[] = [];
      for (const line of source.split(/\r?\n/)) {
        if (!line.trim()) continue;
        try {
          payloads.push(JSON.parse(line));
        } catch {
          throw new Error(`Facebook returned an unreadable response for ${operation}`);
        }
      }
      return { response, payloads };
    };

    let result = await invoke();
    const failed = !result.response.ok || result.payloads.some((payload) => Array.isArray(payload.errors));
    if (failed && await refreshDocId(operation)) result = await invoke();
    if (!result.response.ok || result.payloads.some((payload) => Array.isArray(payload.errors))) {
      throw new Error(`Facebook could not complete ${operation}`);
    }
    return result.payloads;
  };

  const variables = (operation: OperationName): JsonObject => clone(operationBaselines[operation].variables);

  action("getSignInUrl", { async invoke() { return { url: "https://www.facebook.com/login/" }; } });
  action("getSignInState", {
    async invoke() {
      const signedOut = Boolean(document.querySelector('form[action*="login"], input[name="email"], input[name="pass"]'));
      const signedIn = Boolean(token("fb_dtsg", ["DTSGInitialData", "DTSG"]));
      return { signedIn: signedIn && !signedOut };
    },
  });

  action("listGroupPosts", {
    async invoke({ groupId, cursor, limit }: { groupId?: string; cursor?: string; limit?: number } = {}) {
      const operation: OperationName = cursor
        ? "GroupsCometFeedRegularStoriesPaginationQuery"
        : "CometGroupDiscussionRootSuccessQuery";
      const args = variables(operation);
      const count = Math.min(Math.max(Number(limit) || 5, 1), 20);
      if (cursor) {
        args.id = groupId;
        args.cursor = cursor;
        args.count = count;
      } else {
        args.groupID = groupId;
        args.regular_stories_count = count;
        args.regular_stories_stream_initial_count = count;
      }
      const payloads = await request(operation, args);
      return { items: groupPosts(payloads), nextCursor: nextCursor(payloads) };
    },
  });

  action("listFriendSuggestions", {
    async invoke({ cursor, limit }: { cursor?: string; limit?: number } = {}) {
      const operation: OperationName = cursor ? "FriendingCometPYMKGridPaginationQuery" : "FriendingCometRootContentQuery";
      const args = variables(operation);
      if (cursor) {
        args.cursor = cursor;
        args.count = Math.min(Math.max(Number(limit) || 20, 1), 50);
      }
      const payloads = await request(operation, args);
      const pymk = payloads[0]?.data?.viewer?.pymk_grid;
      return { items: friendSuggestions(payloads), nextCursor: nextCursor(payloads, pymk) };
    },
  });

  action("listMarketplace", {
    async invoke({ latitude, longitude, radiusKm, cursor, limit }: {
      latitude?: number;
      longitude?: number;
      radiusKm?: number;
      cursor?: string;
      limit?: number;
    } = {}) {
      const operation: OperationName = cursor
        ? "MarketplaceCometBrowseFeedLightPaginationQuery"
        : "MarketplaceCometBrowseFeedLightContainerQuery";
      const args = variables(operation);
      args.buyLocation = { latitude, longitude };
      args.radius = (Number(radiusKm) || 65) * 1000;
      args.count = Math.min(Math.max(Number(limit) || 12, 1), 50);
      args.cursor = cursor || null;
      const payloads = await request(operation, args);
      return { items: marketplaceListings(payloads), nextCursor: nextCursor(payloads) };
    },
  });

  action("searchMarketplace", {
    async invoke({ query, latitude, longitude, radiusKm, cursor, limit }: {
      query?: string;
      latitude?: number;
      longitude?: number;
      radiusKm?: number;
      cursor?: string;
      limit?: number;
    } = {}) {
      const operation: OperationName = cursor
        ? "CometMarketplaceSearchContentPaginationQuery"
        : "CometMarketplaceSearchContentContainerQuery";
      const args = variables(operation);
      const search = String(query || "").trim();
      const radius = Number(radiusKm) || 65;
      args.count = Math.min(Math.max(Number(limit) || 24, 1), 50);
      args.cursor = cursor || null;
      if (args.buyLocation) args.buyLocation = { latitude, longitude };
      args.params.bqf.query = search;
      args.params.browse_request_params.filter_location_latitude = latitude;
      args.params.browse_request_params.filter_location_longitude = longitude;
      args.params.browse_request_params.filter_radius_km = radius;
      if ("savedSearchQuery" in args) args.savedSearchQuery = search;
      const payloads = await request(operation, args);
      const feed = payloads[0]?.data?.marketplace_search?.feed_units;
      return { items: marketplaceListings(payloads), nextCursor: nextCursor(payloads, feed) };
    },
  });
};

export default install;
