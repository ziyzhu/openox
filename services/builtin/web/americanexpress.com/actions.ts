import type { ActionInstaller } from "../action.ts";

const install: ActionInstaller = ({ action, retryFetch, log }) => {
  const ORIGIN = "https://www.americanexpress.com";
  const START_URL = `${ORIGIN}/en-us/travel`;
  const LOGIN_URL = `${ORIGIN}/en-us/account/login`;
  const GATEWAY = "https://apigw.americanexpress.com/travel/v2";
  const CLIENT_ID = "684C957199C3BE6C153A778D1986032B";

  const uuid = () =>
    "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
      const r = (Math.random() * 16) | 0;
      return (c === "x" ? r : (r & 0x3) | 0x8).toString(16);
    });

  const bookingHeaders = () => ({
    accept: "application/json",
    "x-client-id": CLIENT_ID,
    "x-correlation-id": uuid(),
    "x-locale": "en-US",
  });

  const profileHeaders = () => ({
    accept: "application/json",
    clientId: "TLSONLINE",
    correlationId: uuid(),
    encryption_mech: "TLST1",
  });

  const call = async (
    path: string,
    headers: Record<string, string>,
    init?: RequestInit,
  ) => {
    const r = await retryFetch(`${GATEWAY}${path}`, {
      credentials: "include",
      ...init,
      headers: { ...headers, ...(init?.headers as Record<string, string>) },
    });
    if (!r.ok) throw new Error(`${init?.method ?? "GET"} ${path.split("?")[0]} HTTP ${r.status}`);
    return r.json();
  };

  const firstArray = (j: any, keys: string[]): any[] => {
    if (Array.isArray(j)) return j;
    for (const k of keys) if (Array.isArray(j?.[k])) return j[k];
    for (const v of Object.values(j ?? {})) if (Array.isArray(v)) return v as any[];
    return [];
  };

  const text = (...values: unknown[]): string | null => {
    const value = values.find((candidate) => typeof candidate === "string" || typeof candidate === "number");
    return value === undefined ? null : String(value);
  };

  const loyalty = (item: any) => ({
    program: text(item?.programName, item?.program_name, item?.loyaltyProgramName, item?.name),
    membershipNumber: text(item?.membershipNumber, item?.membership_number, item?.memberNumber, item?.number),
    vendor: text(item?.vendorName, item?.vendor_name, item?.vendor, item?.providerName),
    status: text(item?.status, item?.statusText),
  });

  const trip = (item: any) => ({
    tripId: text(item?.tripId, item?.trip_id, item?.bookingId, item?.booking_id, item?.id),
    bookingDate: text(item?.bookingDate, item?.booking_date, item?.createdDate, item?.created_at),
    title: text(item?.title, item?.tripName, item?.name),
    type: text(item?.tripType, item?.type, item?.productType),
    status: text(item?.status, item?.bookingStatus),
    startDate: text(item?.startDate, item?.departureDate, item?.checkInDate),
    endDate: text(item?.endDate, item?.returnDate, item?.checkOutDate),
    destination: text(item?.destinationName, item?.destination, item?.location),
  });

  const segment = (item: any) => ({
    type: text(item?.segmentType, item?.type, item?.productType),
    title: text(item?.title, item?.name, item?.description),
    origin: text(item?.originName, item?.origin, item?.from),
    destination: text(item?.destinationName, item?.destination, item?.to),
    startDate: text(item?.startDate, item?.departureDate, item?.checkInDate),
    endDate: text(item?.endDate, item?.arrivalDate, item?.checkOutDate),
    status: text(item?.status, item?.bookingStatus),
    confirmationNumber: text(item?.confirmationNumber, item?.confirmation_number, item?.recordLocator),
  });

  let profileIdCache: string | null = null;
  const fetchProfile = async () => {
    const j = await call("/profile_mgmt/profiles/inquiry_results", profileHeaders(), {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({}),
    });
    profileIdCache = j?.profile_id ?? null;
    return j;
  };
  const profileId = async () => profileIdCache ?? (await fetchProfile(), profileIdCache);

  action("getSignInUrl", { async invoke() { return { url: LOGIN_URL }; } });

  action("getSignInState", {
    async invoke() {
      try {
        const r = await retryFetch(`${GATEWAY}/profile_mgmt/profiles/inquiry_results`, {
          method: "POST",
          credentials: "include",
          headers: { ...profileHeaders(), "content-type": "application/json" },
          body: JSON.stringify({}),
        });
        const signedIn = r.ok;
        log(`getSignInState: status=${r.status} signedIn=${signedIn}`);
        if (!signedIn && r.status !== 401 && r.status !== 403) {
          throw new Error(`getSignInState HTTP ${r.status}`);
        }
        return { signedIn };
      } catch (e: any) {
        log("getSignInState: " + (e?.message ?? String(e)));
        throw e;
      }
    },
  });

  action("getProfile", {
    async invoke() {
      try {
        const j = await fetchProfile();
        const cards = Array.isArray(j?.cards_list) ? j.cards_list : [];
        const name = typeof j?.name === "string"
          ? j.name
          : j?.name?.full_name ?? j?.name?.fullName
            ?? [j?.name?.first_name ?? j?.name?.firstName, j?.name?.last_name ?? j?.name?.lastName]
              .filter(Boolean).join(" ");
        log(`getProfile: profileId=${j?.profile_id ?? "?"} cards=${cards.length}`);
        return {
          profileId: j?.profile_id ?? null,
          name: name || null,
          cardsCount: cards.length,
        };
      } catch (e: any) {
        log("getProfile: " + (e?.message ?? String(e)));
        throw e;
      }
    },
  });

  action("listLoyalties", {
    async invoke() {
      try {
        const id = await profileId();
        if (!id) throw new Error("no profileId available");
        const j = await call(`/profile_mgmt/profiles/${id}/primary_traveler/loyalties`, profileHeaders());
        const items = firstArray(j, ["loyalties"]).map(loyalty);
        log(`listLoyalties: ${items.length} programs`);
        return { items, nextCursor: null };
      } catch (e: any) {
        log("listLoyalties: " + (e?.message ?? String(e)));
        throw e;
      }
    },
  });

  action("listTrips", {
    async invoke({ tripType }: { tripType?: string } = {}) {
      try {
        const type = (tripType ?? "upcoming").toLowerCase();
        const j = await call(`/bookings/summary?type=${type}`, bookingHeaders(), {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({}),
        });
        const items = firstArray(j, ["bookings", "trips", "summary", "items", "results"]).map(trip);
        log(`listTrips: ${items.length} trips (${type})`);
        return { items, nextCursor: null };
      } catch (e: any) {
        log("listTrips: " + (e?.message ?? String(e)));
        throw e;
      }
    },
  });

  action("getTrip", {
    async invoke({ tripId, bookingDate }: { tripId: string; bookingDate: string }) {
      try {
        const j = await call("/bookings/details", bookingHeaders(), {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ tripId, bookingDate }),
        });
        log(`getTrip: tripId=${tripId} keys=${Object.keys(j ?? {}).join(",")}`);
        return {
          ...trip({ ...j, tripId, bookingDate }),
          travelers: firstArray(j, ["travelers", "passengers"]).map((traveler: any) =>
            text(traveler?.fullName, traveler?.name, traveler?.travelerName),
          ).filter((name): name is string => name !== null),
          segments: firstArray(j, ["segments", "flights", "hotels", "cars", "items"]).map(segment),
        };
      } catch (e: any) {
        log("getTrip: " + (e?.message ?? String(e)));
        throw e;
      }
    },
  });
};

export default install;
