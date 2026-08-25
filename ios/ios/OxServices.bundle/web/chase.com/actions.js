(() => {
  // service-sdk/action-lib.ts
  function pageCursor(value, firstPage) {
    return Math.max(firstPage, Number.parseInt(value ?? String(firstPage), 10) || firstPage);
  }

  // services/builtin/web/chase.com/actions.ts
  var install = ({ action, retryFetch, log }) => {
    const START_URL = "https://secure.chase.com/web/auth/nav?navKey=chaseTravelHome&treatment=chase";
    const GATEWAY = "https://secure.chase.com/svc/wr/profile/l4/gateway/chase-travel/loyalty/bank-rewards/cte-app/v1";
    const uuid = () => "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
      const r = Math.random() * 16 | 0;
      return (c === "x" ? r : r & 3 | 8).toString(16);
    });
    const jpmcHeaders = () => ({
      accept: "application/json",
      "x-jpmc-csrf-token": "NONE",
      "x-jpmc-channel": "id=C30",
      channeltype: "WEB",
      onlineindicator: "true",
      mockindicator: "false",
      "x-jpmc-client-request-id": uuid()
    });
    const get = async (path) => {
      const r = await retryFetch(`${GATEWAY}${path}`, {
        credentials: "include",
        headers: jpmcHeaders()
      });
      if (!r.ok)
        throw new Error(`GET ${path.split("?")[0]} HTTP ${r.status}`);
      return r.json();
    };
    const post = async (path, body) => {
      const r = await retryFetch(`${GATEWAY}${path}`, {
        method: "POST",
        credentials: "include",
        headers: { ...jpmcHeaders(), "content-type": "application/json" },
        body: JSON.stringify(body)
      });
      if (!r.ok)
        throw new Error(`POST ${path.split("?")[0]} HTTP ${r.status}`);
      return r.json();
    };
    const firstArray = (j, keys) => {
      if (Array.isArray(j))
        return j;
      for (const k of keys)
        if (Array.isArray(j?.[k]))
          return j[k];
      for (const v of Object.values(j ?? {}))
        if (Array.isArray(v))
          return v;
      return [];
    };
    const text = (...values) => {
      const value = values.find((candidate) => typeof candidate === "string" || typeof candidate === "number");
      return value === undefined ? null : String(value);
    };
    const amount = (...values) => {
      const value = values.find((candidate) => typeof candidate === "number" || typeof candidate === "string" && Number.isFinite(Number(candidate)));
      return value === undefined ? null : Number(value);
    };
    const trip = (item) => ({
      id: text(item?.tripId, item?.trip_id, item?.bookingId, item?.id),
      title: text(item?.title, item?.tripName, item?.name),
      type: text(item?.tripType, item?.type, item?.productType),
      status: text(item?.status, item?.bookingStatus),
      startDate: text(item?.startDate, item?.departureDate, item?.checkInDate),
      endDate: text(item?.endDate, item?.returnDate, item?.checkOutDate),
      destination: text(item?.destinationName, item?.destination?.name, item?.destination, item?.location)
    });
    const recentHotelSearch = (item) => {
      const destination = item?.destination ?? item?.dstn ?? item;
      return {
        destination: text(destination?.name, destination?.label, destination?.city, item?.destinationName),
        checkIn: text(item?.checkIn, item?.checkInDate, item?.startDate),
        checkOut: text(item?.checkOut, item?.checkOutDate, item?.endDate),
        payload: JSON.stringify(destination)
      };
    };
    const recentFlightSearch = (item) => ({
      origin: text(item?.origin?.name, item?.originName, item?.origin, item?.from),
      destination: text(item?.destination?.name, item?.destinationName, item?.destination, item?.to),
      departureDate: text(item?.departureDate, item?.startDate),
      returnDate: text(item?.returnDate, item?.endDate),
      tripType: text(item?.tripType, item?.type)
    });
    const deal = (item) => ({
      id: text(item?.dealId, item?.id, item?.identifier),
      title: text(item?.title, item?.name, item?.headline),
      description: text(item?.description, item?.summary),
      destination: text(item?.destinationName, item?.destination, item?.location),
      price: amount(item?.price?.amount, item?.price, item?.amount),
      currency: text(item?.price?.currency, item?.currency, item?.currencyCode),
      url: text(item?.url, item?.link, item?.deeplink)
    });
    const hotel = (item) => ({
      id: text(item?.hotelId, item?.propertyId, item?.id),
      name: text(item?.hotelName, item?.name, item?.title),
      location: text(item?.locationName, item?.location, item?.address?.city),
      rating: amount(item?.rating, item?.starRating),
      price: amount(item?.price?.amount, item?.lowestPrice?.amount, item?.price),
      currency: text(item?.price?.currency, item?.lowestPrice?.currency, item?.currency),
      imageUrl: text(item?.imageUrl, item?.image?.url, item?.thumbnailUrl)
    });
    const nextCursor = (items, pn, ps) => items.length >= ps ? String(pn + 1) : null;
    let accountsCache = null;
    const accounts = async () => {
      if (accountsCache)
        return accountsCache;
      const j = await get("/travel-profiles?all-accounts-hidden-indicator=true");
      accountsCache = Array.isArray(j?.accounts) ? j.accounts : [];
      return accountsCache ?? [];
    };
    const primaryAccountId = async () => {
      const a = await accounts();
      return a[0]?.digitalAccountIdentifier ?? null;
    };
    action("getSignInUrl", { async invoke() {
      return { url: START_URL };
    } });
    action("getSignInState", {
      async invoke() {
        try {
          const r = await retryFetch(`${GATEWAY}/travel-profiles?all-accounts-hidden-indicator=true`, {
            credentials: "include",
            headers: jpmcHeaders()
          });
          const signedIn = r.ok;
          log(`getSignInState: status=${r.status} signedIn=${signedIn}`);
          if (!signedIn && r.status !== 401 && r.status !== 403) {
            throw new Error(`getSignInState HTTP ${r.status}`);
          }
          return { signedIn };
        } catch (e) {
          log("getSignInState: " + (e?.message ?? String(e)));
          throw e;
        }
      }
    });
    action("getTravelProfile", {
      async invoke() {
        try {
          accountsCache = null;
          const j = await get("/travel-profiles?all-accounts-hidden-indicator=true");
          const accts = Array.isArray(j?.accounts) ? j.accounts : [];
          accountsCache = accts;
          log(`getTravelProfile: ${accts.length} accounts`);
          return {
            loyaltyProfileIdentifier: j?.loyaltyProfileIdentifier ?? null,
            enterprisePartyIdentifier: j?.enterprisePartyIdentifier ?? null,
            onlineProfileIdentifier: j?.onlineProfileIdentifier ?? null,
            accounts: accts.map((a) => ({
              digitalAccountIdentifier: a?.digitalAccountIdentifier ?? null,
              accountNicknameText: a?.accountNicknameText ?? null,
              last4AccountNumber: a?.last4AccountNumber ?? null,
              rewardsBalanceAmount: a?.rewardsBalanceAmount ?? null,
              cardCreditLimitAmount: a?.cardSpendControl?.cardCreditLimitAmount ?? null,
              availableCreditAmount: a?.cardSpendControl?.availableCreditAmount ?? null
            }))
          };
        } catch (e) {
          log("getTravelProfile: " + (e?.message ?? String(e)));
          throw e;
        }
      }
    });
    action("getStatementCredits", {
      async invoke({ digitalAccountIdentifier } = {}) {
        try {
          const id = digitalAccountIdentifier ?? await primaryAccountId();
          if (id == null)
            throw new Error("no digitalAccountIdentifier available");
          const j = await get(`/statement-credits?digital-account-identifier=${id}`);
          const credits = Array.isArray(j?.statementCredits) ? j.statementCredits : [];
          log(`getStatementCredits: account=${id} total=${j?.availableStatementCreditAmount ?? "?"} count=${credits.length}`);
          return {
            availableStatementCreditAmount: j?.availableStatementCreditAmount ?? null,
            rewardsAnniversaryDate: j?.rewardsAnniversaryDate ?? null,
            statementCredits: credits.map((credit) => ({
              id: text(credit?.creditId, credit?.id, credit?.identifier),
              name: text(credit?.creditName, credit?.name, credit?.title),
              description: text(credit?.description, credit?.details),
              availableAmount: amount(credit?.availableAmount, credit?.remainingAmount, credit?.amount),
              usedAmount: amount(credit?.usedAmount, credit?.redeemedAmount),
              expirationDate: text(credit?.expirationDate, credit?.endDate, credit?.renewalDate)
            }))
          };
        } catch (e) {
          log("getStatementCredits: " + (e?.message ?? String(e)));
          throw e;
        }
      }
    });
    action("listTrips", {
      async invoke({ tripType, cursor, limit } = {}) {
        try {
          const pn = pageCursor(cursor, 1);
          const ps = limit ?? 50;
          const j = await get(`/proxy/api/mytrip/v1.0/native/trip?pagenumber=${pn}&pagesize=${ps}&tripType=${tripType ?? "Upcoming"}`);
          const items = firstArray(j, ["trips", "items", "results"]).map(trip);
          log(`listTrips: ${items.length} trips (${tripType ?? "Upcoming"} page ${pn})`);
          return { items, nextCursor: nextCursor(items, pn, ps) };
        } catch (e) {
          log("listTrips: " + (e?.message ?? String(e)));
          throw e;
        }
      }
    });
    action("listRecentHotelSearches", {
      async invoke() {
        try {
          const j = await get("/hotel/search/recent");
          const items = firstArray(j, ["s", "searches", "items", "results"]).map(recentHotelSearch);
          log(`listRecentHotelSearches: ${items.length} items`);
          return { items, nextCursor: null };
        } catch (e) {
          log("listRecentHotelSearches: " + (e?.message ?? String(e)));
          throw e;
        }
      }
    });
    action("listRecentFlightSearches", {
      async invoke() {
        try {
          const j = await get("/flight/search/recent");
          const items = firstArray(j, ["locations", "searches", "items", "results"]).map(recentFlightSearch);
          log(`listRecentFlightSearches: ${items.length} items`);
          return { items, nextCursor: null };
        } catch (e) {
          log("listRecentFlightSearches: " + (e?.message ?? String(e)));
          throw e;
        }
      }
    });
    action("listDeals", {
      async invoke({ cursor, limit } = {}) {
        try {
          const pn = pageCursor(cursor, 1);
          const ps = limit ?? 20;
          const j = await get(`/proxy/api/orxe/v1.0/deals/dealFinder?searchCriteria.campaignId=blt6eba58b817284826` + `&searchCriteria.identifier=dealList&pagination.pageNumber=${pn}&pagination.pageSize=${ps}`);
          const items = firstArray(j, ["deals", "items", "results"]).map(deal);
          log(`listDeals: ${items.length} deals (page ${pn})`);
          return { items, nextCursor: nextCursor(items, pn, ps) };
        } catch (e) {
          log("listDeals: " + (e?.message ?? String(e)));
          throw e;
        }
      }
    });
    action("searchHotels", {
      async invoke({ destination, checkIn, checkOut, adults, currency, cursor, limit }) {
        try {
          const cur = currency || "USD";
          const rawDestination = typeof destination?.payload === "string" ? JSON.parse(destination.payload) : destination;
          const created = await post("/proxy/api/hotel/v1.0/search", {
            cur,
            sq: {
              sp: { e: `${checkOut}T00:00:00`, s: `${checkIn}T00:00:00` },
              dstn: rawDestination,
              g: { adt: adults ?? 1, ca: [] },
              st: "hotels",
              ftr: null
            }
          });
          const sid = created?.sid ?? created?.searchId ?? created?.sessionId ?? created?.id ?? created?.data?.sid ?? null;
          log(`searchHotels: created sid=${sid ?? "?"} keys=${Object.keys(created ?? {}).join(",")}`);
          if (!sid)
            throw new Error("no search session id in create response");
          const pn = pageCursor(cursor, 1);
          const ps = limit ?? 16;
          const j = await post("/proxy/api/hotel/v1.0/search/results", {
            cur,
            ftr: {
              b: [],
              cn: [],
              hids: [],
              hs: [],
              idoh: false,
              rt: [],
              tar: [],
              tyr: [],
              amn: [],
              p: { max: null, min: null },
              nh: [],
              rfd: [],
              pt: [],
              cf: null,
              bo: null,
              bd: [],
              bt: [],
              gr: []
            },
            pg: { pn, ps, tr: null },
            sid,
            sb: "boolSortfield1 desc, numberSortfield1 asc, recommendation",
            lm: null
          });
          const items = firstArray(j, ["h", "hotels", "results", "items", "data"]).map(hotel);
          log(`searchHotels: ${items.length} hotels (page ${pn})`);
          return { sid, items, nextCursor: nextCursor(items, pn, ps) };
        } catch (e) {
          log("searchHotels: " + (e?.message ?? String(e)));
          throw e;
        }
      }
    });
    action("getCartCount", {
      async invoke() {
        try {
          const j = await get("/checkout/cartcount");
          log(`getCartCount: ${j?.totalItems ?? j?.numberOfItems ?? "?"}`);
          return {
            numberOfItems: j?.numberOfItems ?? null,
            numberOfAddOnItems: j?.numberOfAddOnItems ?? null,
            totalItems: j?.totalItems ?? null
          };
        } catch (e) {
          log("getCartCount: " + (e?.message ?? String(e)));
          throw e;
        }
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

  installService("chase.com", actions_default);
})();
