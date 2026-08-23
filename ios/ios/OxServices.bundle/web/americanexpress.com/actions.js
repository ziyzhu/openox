(() => {
  // services/builtin/web/americanexpress.com/actions.ts
  var install = ({ action, retryFetch, log }) => {
    const ORIGIN = "https://www.americanexpress.com";
    const START_URL = `${ORIGIN}/en-us/travel`;
    const LOGIN_URL = `${ORIGIN}/en-us/account/login`;
    const GATEWAY = "https://apigw.americanexpress.com/travel/v2";
    const CLIENT_ID = "684C957199C3BE6C153A778D1986032B";
    const uuid = () => "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
      const r = Math.random() * 16 | 0;
      return (c === "x" ? r : r & 3 | 8).toString(16);
    });
    const bookingHeaders = () => ({
      accept: "application/json",
      "x-client-id": CLIENT_ID,
      "x-correlation-id": uuid(),
      "x-locale": "en-US"
    });
    const profileHeaders = () => ({
      accept: "application/json",
      clientId: "TLSONLINE",
      correlationId: uuid(),
      encryption_mech: "TLST1"
    });
    const call = async (path, headers, init) => {
      const r = await retryFetch(`${GATEWAY}${path}`, {
        credentials: "include",
        ...init,
        headers: { ...headers, ...init?.headers }
      });
      if (!r.ok)
        throw new Error(`${init?.method ?? "GET"} ${path.split("?")[0]} HTTP ${r.status}`);
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
    const loyalty = (item) => ({
      program: text(item?.programName, item?.program_name, item?.loyaltyProgramName, item?.name),
      membershipNumber: text(item?.membershipNumber, item?.membership_number, item?.memberNumber, item?.number),
      vendor: text(item?.vendorName, item?.vendor_name, item?.vendor, item?.providerName),
      status: text(item?.status, item?.statusText)
    });
    const trip = (item) => ({
      tripId: text(item?.tripId, item?.trip_id, item?.bookingId, item?.booking_id, item?.id),
      bookingDate: text(item?.bookingDate, item?.booking_date, item?.createdDate, item?.created_at),
      title: text(item?.title, item?.tripName, item?.name),
      type: text(item?.tripType, item?.type, item?.productType),
      status: text(item?.status, item?.bookingStatus),
      startDate: text(item?.startDate, item?.departureDate, item?.checkInDate),
      endDate: text(item?.endDate, item?.returnDate, item?.checkOutDate),
      destination: text(item?.destinationName, item?.destination, item?.location)
    });
    const segment = (item) => ({
      type: text(item?.segmentType, item?.type, item?.productType),
      title: text(item?.title, item?.name, item?.description),
      origin: text(item?.originName, item?.origin, item?.from),
      destination: text(item?.destinationName, item?.destination, item?.to),
      startDate: text(item?.startDate, item?.departureDate, item?.checkInDate),
      endDate: text(item?.endDate, item?.arrivalDate, item?.checkOutDate),
      status: text(item?.status, item?.bookingStatus),
      confirmationNumber: text(item?.confirmationNumber, item?.confirmation_number, item?.recordLocator)
    });
    let profileIdCache = null;
    const fetchProfile = async () => {
      const j = await call("/profile_mgmt/profiles/inquiry_results", profileHeaders(), {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({})
      });
      profileIdCache = j?.profile_id ?? null;
      return j;
    };
    const profileId = async () => profileIdCache ?? (await fetchProfile(), profileIdCache);
    action("getSignInUrl", { async invoke() {
      return { url: LOGIN_URL };
    } });
    action("getSignInState", {
      async invoke() {
        try {
          const r = await retryFetch(`${GATEWAY}/profile_mgmt/profiles/inquiry_results`, {
            method: "POST",
            credentials: "include",
            headers: { ...profileHeaders(), "content-type": "application/json" },
            body: JSON.stringify({})
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
    action("getProfile", {
      async invoke() {
        try {
          const j = await fetchProfile();
          const cards = Array.isArray(j?.cards_list) ? j.cards_list : [];
          const name = typeof j?.name === "string" ? j.name : j?.name?.full_name ?? j?.name?.fullName ?? [j?.name?.first_name ?? j?.name?.firstName, j?.name?.last_name ?? j?.name?.lastName].filter(Boolean).join(" ");
          log(`getProfile: profileId=${j?.profile_id ?? "?"} cards=${cards.length}`);
          return {
            profileId: j?.profile_id ?? null,
            name: name || null,
            cardsCount: cards.length
          };
        } catch (e) {
          log("getProfile: " + (e?.message ?? String(e)));
          throw e;
        }
      }
    });
    action("listLoyalties", {
      async invoke() {
        try {
          const id = await profileId();
          if (!id)
            throw new Error("no profileId available");
          const j = await call(`/profile_mgmt/profiles/${id}/primary_traveler/loyalties`, profileHeaders());
          const items = firstArray(j, ["loyalties"]).map(loyalty);
          log(`listLoyalties: ${items.length} programs`);
          return { items, nextCursor: null };
        } catch (e) {
          log("listLoyalties: " + (e?.message ?? String(e)));
          throw e;
        }
      }
    });
    action("listTrips", {
      async invoke({ tripType } = {}) {
        try {
          const type = (tripType ?? "upcoming").toLowerCase();
          const j = await call(`/bookings/summary?type=${type}`, bookingHeaders(), {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({})
          });
          const items = firstArray(j, ["bookings", "trips", "summary", "items", "results"]).map(trip);
          log(`listTrips: ${items.length} trips (${type})`);
          return { items, nextCursor: null };
        } catch (e) {
          log("listTrips: " + (e?.message ?? String(e)));
          throw e;
        }
      }
    });
    action("getTrip", {
      async invoke({ tripId, bookingDate }) {
        try {
          const j = await call("/bookings/details", bookingHeaders(), {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ tripId, bookingDate })
          });
          log(`getTrip: tripId=${tripId} keys=${Object.keys(j ?? {}).join(",")}`);
          return {
            ...trip({ ...j, tripId, bookingDate }),
            travelers: firstArray(j, ["travelers", "passengers"]).map((traveler) => text(traveler?.fullName, traveler?.name, traveler?.travelerName)).filter((name) => name !== null),
            segments: firstArray(j, ["segments", "flights", "hotels", "cars", "items"]).map(segment)
          };
        } catch (e) {
          log("getTrip: " + (e?.message ?? String(e)));
          throw e;
        }
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

  installService("americanexpress.com", actions_default);
})();
