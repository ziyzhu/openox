(() => {
  // service-sdk/action-lib.ts
  function cleanText(value) {
    return String(value ?? "").replace(/\s+/g, " ").trim();
  }

  // services/builtin/web/www.airbnb.com/actions.ts
  var ORIGIN = "https://www.airbnb.com";
  var API_KEY = "d306zoyjsyarp7ifhu67rjxn52tv0t20";
  var HASHES = {
    staysSearch: "0f40636efe5e24f2d373e6a0c5b6a87be6eb2e0ddbad0a1045fed81f5415b53e",
    servicesSearch: "a0d9e9da651fea13ab619c89221d5e14897ae3fad7df9a62aceb86b8ed658f10",
    stayAvailability: "be60714ead0a30db42ce6471ddad6a8f3855df0ed400b79282dd0bb8cecdf201",
    stayReviews: "cfdc3ffbe997a618795fc5a8f9a9b484054ce9be68c8788cd2ffda999934c5ae",
    upcomingTrips: "219c3c5c1841a3b2c4fed9329a0708dd384b987515e24c8eda8af1608af69608",
    pastTrips: "eb6f3f145595b38c403a2c0f209555a514e4ba4bc45b3a2526fc71f8b47b22b4",
    tripDetails: "2de2346883822f98ab1730df6d608cd65a5ab05f17a72e3c3edfc5b2b39f2056",
    wishlists: "b8b421d802c399b55fb6ac1111014807a454184ad38f198365beb7836c018c18"
  };
  var headers = {
    accept: "application/json",
    "content-type": "application/json",
    "x-airbnb-api-key": API_KEY,
    "x-airbnb-graphql-platform": "web",
    "x-airbnb-graphql-platform-client": "minimalist-niobe",
    "x-csrf-without-token": "1"
  };
  var graphIdPart = (value) => {
    try {
      const padded = value + "=".repeat((4 - value.length % 4) % 4);
      const decoded = atob(padded);
      const index = decoded.indexOf(":");
      return index >= 0 ? decoded.slice(index + 1) : null;
    } catch {
      return null;
    }
  };
  var numericId = (value) => graphIdPart(value) ?? value.match(/\d+/)?.[0] ?? value;
  var stayId = (value) => {
    const id = numericId(cleanText(value));
    if (!/^\d+$/.test(id))
      throw new Error(`Invalid Airbnb stay id: ${JSON.stringify(value)}`);
    return id;
  };
  var tripGraphId = (value) => {
    const raw = cleanText(value);
    const decoded = graphIdPart(raw);
    if (decoded && /^\d+$/.test(decoded))
      return raw;
    const numeric = raw.match(/\d+/)?.[0];
    if (!numeric)
      throw new Error(`Invalid Airbnb trip id: ${JSON.stringify(value)}`);
    return btoa(`Trip:${numeric}`);
  };
  var scalarText = (value) => cleanText(typeof value === "string" ? value : "");
  var ratingParts = (value) => {
    const text = scalarText(value);
    const rating = Number.parseFloat(text.match(/\d+(?:\.\d+)?/)?.[0] ?? "");
    const reviews = Number.parseInt(text.match(/\(([\d,]+)\)/)?.[1]?.replace(/,/g, "") ?? "", 10);
    return {
      rating: Number.isFinite(rating) ? rating : null,
      reviewCount: Number.isFinite(reviews) ? reviews : null
    };
  };
  var dateValue = (value, name) => {
    const date = scalarText(value);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date))
      throw new Error(`${name} must use YYYY-MM-DD`);
    return date;
  };
  var rawParam = (filterName, value) => ({
    filterName,
    filterValues: [String(value)]
  });
  var numberFromItems = (items, label) => {
    if (!Array.isArray(items))
      return null;
    const match = items.map(scalarText).join(" ").match(new RegExp(`(\\d+(?:\\.\\d+)?)\\s+${label}s?\\b`, "i"));
    const value = Number(match?.[1]);
    return Number.isFinite(value) ? value : null;
  };
  var localDateTime = (date) => {
    const pad = (value) => String(value).padStart(2, "0");
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
  };
  var transactionKey = (args) => [
    stayId(args.listingId),
    dateValue(args.checkIn, "checkIn"),
    dateValue(args.checkOut, "checkOut"),
    Number(args.adults ?? 1),
    Number(args.children ?? 0),
    Number(args.infants ?? 0),
    Number(args.pets ?? 0)
  ].join(":");
  var COMPLETED_RESERVATIONS_KEY = "ox.airbnb.completedReservations.v1";
  var ACTIVE_RESERVATION_KEY = "ox.airbnb.activeReservation.v1";
  var install = ({ action, retryFetch, log }) => {
    const requestGet = async (operationName, hash, variables) => {
      const params = new URLSearchParams({
        operationName,
        locale: "en",
        currency: "USD",
        variables: JSON.stringify(variables),
        extensions: JSON.stringify({ persistedQuery: { version: 1, sha256Hash: hash } })
      });
      return retryFetch(`${ORIGIN}/api/v3/${operationName}/${hash}?${params}`, {
        credentials: "include",
        headers
      });
    };
    const graphGet = async (operationName, hash, variables) => {
      const res = await requestGet(operationName, hash, variables);
      if (!res.ok)
        throw new Error(`${operationName} HTTP ${res.status}`);
      const json = await res.json();
      if (json?.errors?.length)
        throw new Error(`${operationName}: ${json.errors[0]?.message || "request failed"}`);
      return json?.data;
    };
    const graphPost = async (operationName, hash, variables) => {
      const params = new URLSearchParams({ operationName, locale: "en", currency: "USD" });
      const res = await retryFetch(`${ORIGIN}/api/v3/${operationName}/${hash}?${params}`, {
        method: "POST",
        credentials: "include",
        headers,
        body: JSON.stringify({
          operationName,
          variables,
          extensions: { persistedQuery: { version: 1, sha256Hash: hash } }
        })
      });
      if (!res.ok)
        throw new Error(`${operationName} HTTP ${res.status}`);
      const json = await res.json();
      if (json?.errors?.length)
        throw new Error(`${operationName}: ${json.errors[0]?.message || "request failed"}`);
      return json?.data;
    };
    const tripRow = (trip) => {
      const scheduled = trip?.scheduledItems?.edges?.[0]?.node;
      const reservation = scheduled?.details?.stayReservation;
      const supply = reservation?.supplyListing;
      const coordinate = trip?.location?.coordinate ?? scheduled?.guestFacingLocation?.obfuscatedCoordinate ?? {};
      const travelerNames = [...new Set((trip?.travelers?.edges ?? []).map((edge) => scalarText(edge?.node?.user?.displayFirstName)).filter(Boolean))];
      return {
        id: String(trip?.id ?? ""),
        listingId: supply?.id ? numericId(String(supply.id)) : null,
        name: scalarText(trip?.displayName),
        status: scalarText(trip?.status),
        startTime: scalarText(trip?.startTime?.dateTime),
        endTime: scalarText(trip?.endTime?.dateTime),
        timeZone: scalarText(trip?.startTime?.listingTimeZone),
        confirmationCode: reservation?.confirmationCode ? String(reservation.confirmationCode) : null,
        pendingExpiresAt: reservation?.pendingExpiresAt ? String(reservation.pendingExpiresAt) : null,
        guestCount: Number(trip?.travelerCapacity?.numberOfAdults) || 0,
        travelerCount: Number(trip?.travelers?.pageInfo?.totalCount) || travelerNames.length,
        travelerNames,
        latitude: Number.isFinite(Number(coordinate?.latitude)) ? Number(coordinate.latitude) : null,
        longitude: Number.isFinite(Number(coordinate?.longitude)) ? Number(coordinate.longitude) : null,
        imageUrl: trip?.coverPhoto?.uri ? String(trip.coverPhoto.uri) : null,
        url: `${ORIGIN}/trips/v1/${encodeURIComponent(numericId(String(trip?.id ?? "")))}`
      };
    };
    action("getSignInUrl", {
      async invoke() {
        return { url: `${ORIGIN}/login` };
      }
    });
    action("getSignInState", {
      async invoke() {
        const res = await requestGet("TripListQuery", HASHES.upcomingTrips, {});
        if (!res.ok) {
          if (res.status === 401 || res.status === 403)
            return { signedIn: false };
          throw new Error(`getSignInState HTTP ${res.status}`);
        }
        const text = await res.text();
        if (!text.trim().startsWith("{"))
          return { signedIn: false };
        const json = JSON.parse(text);
        return { signedIn: Boolean(json?.data?.viewer?.trips) };
      }
    });
    action("searchStays", {
      async invoke({
        query,
        checkIn,
        checkOut,
        adults = 1,
        children = 0,
        infants = 0,
        pets = 0,
        minBathrooms,
        freeParking = false,
        maxPrice,
        cursor,
        limit = 18
      } = {}) {
        const start = dateValue(checkIn, "checkIn");
        const end = dateValue(checkOut, "checkOut");
        if (end <= start)
          throw new Error("checkOut must be after checkIn");
        const rawParams = [
          rawParam("query", scalarText(query)),
          rawParam("checkin", start),
          rawParam("checkout", end),
          rawParam("adults", adults),
          rawParam("children", children),
          rawParam("infants", infants),
          rawParam("pets", pets),
          rawParam("datePickerType", "calendar"),
          rawParam("itemsPerGrid", limit),
          rawParam("refinementPaths", "/homes"),
          rawParam("screenSize", "large"),
          rawParam("tabId", "home_tab"),
          rawParam("version", "1.8.8")
        ];
        if (minBathrooms !== undefined)
          rawParams.push(rawParam("minBathrooms", minBathrooms));
        if (freeParking)
          rawParams.push(rawParam("amenities", 9));
        if (maxPrice !== undefined) {
          const nights = Math.round((Date.parse(end) - Date.parse(start)) / 86400000);
          rawParams.push(rawParam("priceFilterInputType", 2));
          rawParams.push(rawParam("priceFilterNumNights", nights));
          rawParams.push(rawParam("priceMax", maxPrice));
        }
        const mapParams = rawParams.filter((item) => item.filterName !== "itemsPerGrid");
        const treatmentFlags = [
          "feed_map_decouple_m11_treatment",
          "recommended_amenities_2024_treatment_b",
          "filter_redesign_2024_treatment",
          "filter_reordering_2024_roomtype_treatment",
          "p2_category_bar_removal_treatment",
          "selected_filters_2024_treatment",
          "recommended_filters_2024_treatment_b",
          "m13_search_input_phase2_treatment",
          "m13_search_input_services_enabled",
          "m13_2025_experiences_p2_treatment",
          "homes_p25_refresh_2025_treatment"
        ];
        const request = {
          metadataOnly: false,
          requestedPageType: "STAYS_SEARCH",
          searchType: "filter_change",
          treatmentFlags,
          rawParams
        };
        if (cursor)
          request.cursor = cursor;
        const data = await graphPost("StaysSearch", HASHES.staysSearch, {
          staysSearchRequest: { ...request, maxMapItems: 9999 },
          staysMapSearchRequestV2: { ...request, rawParams: mapParams },
          isLeanTreatment: false,
          aiSearchEnabled: false
        });
        const results = data?.presentation?.staysSearch?.results;
        const items = (results?.searchResults ?? []).map((stay) => {
          const listing = stay?.demandStayListing ?? {};
          const graphId = String(listing?.id ?? "");
          const id = numericId(graphId);
          const rating = ratingParts(stay?.avgRatingLocalized ?? stay?.avgRatingA11yLabel);
          const coordinate = listing?.location?.coordinate ?? {};
          const details = (stay?.structuredContent?.primaryLine ?? []).map((line) => scalarText(line?.body)).filter(Boolean);
          return {
            id,
            url: `${ORIGIN}/rooms/${encodeURIComponent(id)}?check_in=${encodeURIComponent(start)}&check_out=${encodeURIComponent(end)}&adults=${encodeURIComponent(String(adults))}`,
            name: scalarText(stay?.nameLocalized?.localizedStringWithTranslationPreference ?? listing?.description?.name?.localizedStringWithTranslationPreference),
            title: scalarText(stay?.title),
            subtitle: scalarText(stay?.subtitle),
            rating: rating.rating,
            reviewCount: rating.reviewCount,
            priceText: scalarText(stay?.structuredDisplayPrice?.primaryLine?.accessibilityLabel ?? stay?.structuredDisplayPrice?.primaryLine?.discountedPrice),
            details,
            badges: (stay?.badges ?? []).map((badge) => scalarText(badge?.text)).filter(Boolean),
            latitude: Number.isFinite(Number(coordinate?.latitude)) ? Number(coordinate.latitude) : null,
            longitude: Number.isFinite(Number(coordinate?.longitude)) ? Number(coordinate.longitude) : null,
            imageUrl: stay?.contextualPictures?.[0]?.picture ? String(stay.contextualPictures[0].picture) : null
          };
        });
        const cursors = results?.paginationInfo?.pageCursors ?? [];
        const index = cursor ? cursors.indexOf(cursor) : 0;
        const nextCursor = index >= 0 && index + 1 < cursors.length ? cursors[index + 1] : null;
        log(`searchStays ${scalarText(query)}: ${items.length} results`);
        return { items, nextCursor };
      }
    });
    action("getStay", {
      async invoke({ id } = {}) {
        const listingId = stayId(id);
        const url = `${ORIGIN}/rooms/${encodeURIComponent(listingId)}`;
        const res = await retryFetch(url, { credentials: "include" });
        if (!res.ok)
          throw new Error(`Airbnb stay ${JSON.stringify(id)} HTTP ${res.status}`);
        const doc = new DOMParser().parseFromString(await res.text(), "text/html");
        const deferredText = doc.querySelector("#data-deferred-state-0")?.textContent;
        if (!deferredText)
          throw new Error(`Airbnb stay ${JSON.stringify(id)} did not include listing details`);
        const deferred = JSON.parse(deferredText);
        const record = (deferred?.niobeClientData ?? []).find((entry) => String(entry?.[0] ?? "").startsWith("StaysPdpSections:"));
        const data = record?.[1]?.data;
        const node = data?.node;
        const pdp = node?.pdpPresentation;
        if (!pdp)
          throw new Error(`Airbnb stay ${JSON.stringify(id)} was not found`);
        const sections = data?.presentation?.stayProductDetailPage?.sections?.sections ?? [];
        const section = (sectionId) => sections.find((item) => item?.sectionId === sectionId)?.section;
        const policies = section("POLICIES_DEFAULT") ?? {};
        const host = section("MEET_YOUR_HOST")?.cardData ?? {};
        const overviewItems = pdp?.overview?.items ?? [];
        const descriptionHtml = scalarText(pdp?.descriptions?.longDescriptionHtml?.localizedStringWithTranslationPreference);
        const descriptionDoc = new DOMParser().parseFromString(descriptionHtml, "text/html");
        const amenities = (pdp?.amenities?.seeAllAmenitiesGroups ?? []).flatMap((group) => (group?.amenities ?? []).map((amenity) => ({
          name: scalarText(amenity?.title),
          group: scalarText(group?.title),
          available: Boolean(amenity?.available),
          details: scalarText(amenity?.subtitle?.text ?? amenity?.subtitle?.content?.localizedStringWithTranslationPreference)
        }))).filter((amenity) => amenity.name);
        const policyItems = (groups) => (groups ?? []).flatMap((group) => (group?.items ?? []).map((item) => [scalarText(item?.title), scalarText(item?.subtitle)].filter(Boolean).join(": "))).filter(Boolean);
        const quality = pdp?.quality?.listingRatingStats?.overallRatingStats ?? node?.listingRatingStats?.overallRatingStats ?? {};
        const name = scalarText(pdp?.title?.content?.localizedStringWithTranslationPreference);
        if (!name)
          throw new Error(`Airbnb stay ${JSON.stringify(id)} did not include a title`);
        const output = {
          id: listingId,
          url,
          name,
          propertyType: scalarText(pdp?.sharingConfig?.propertyType),
          location: scalarText(pdp?.overview?.title ?? pdp?.localizedLocation ?? node?.location?.city),
          description: cleanText(descriptionDoc.body?.textContent ?? descriptionHtml),
          guestCapacity: Number(pdp?.personCapacity ?? node?.personCapacity) || 0,
          bedrooms: numberFromItems(overviewItems, "bedroom"),
          beds: numberFromItems(overviewItems, "bed"),
          bathrooms: numberFromItems(overviewItems, "(?:private )?bath"),
          rating: Number.isFinite(Number(quality?.ratingAverage)) ? Number(quality.ratingAverage) : null,
          reviewCount: Number.isFinite(Number(quality?.ratingCount)) ? Number(quality.ratingCount) : null,
          hostName: scalarText(host?.name ?? node?.contextualPrimaryHost?.user?.presentation?.displayName),
          hostSuperhost: Boolean(host?.isSuperhost),
          highlights: (pdp?.highlights ?? []).map((highlight) => [
            scalarText(highlight?.headline?.localizedContent),
            scalarText(highlight?.body?.localizedContent)
          ].filter(Boolean).join(": ")).filter(Boolean),
          amenities,
          houseRules: policyItems(policies?.houseRulesSections),
          safety: policyItems(policies?.safetyAndPropertiesSections),
          latitude: Number.isFinite(Number(node?.location?.coordinate?.latitude)) ? Number(node.location.coordinate.latitude) : null,
          longitude: Number.isFinite(Number(node?.location?.coordinate?.longitude)) ? Number(node.location.coordinate.longitude) : null,
          imageUrls: (pdp?.heroMedia?.edges ?? []).map((edge) => scalarText(edge?.node?.image?.uri)).filter(Boolean)
        };
        log(`getStay ${listingId}: ${output.name}`);
        return output;
      }
    });
    action("getStayAvailability", {
      async invoke({ id, startMonth, months = 12 } = {}) {
        const listingId = stayId(id);
        const match = scalarText(startMonth).match(/^(\d{4})-(\d{2})$/);
        const year = Number(match?.[1]);
        const month = Number(match?.[2]);
        if (!match || month < 1 || month > 12)
          throw new Error("startMonth must use YYYY-MM");
        const data = await graphGet("PdpAvailabilityCalendar", HASHES.stayAvailability, {
          request: {
            count: months,
            listingId,
            month,
            year,
            returnPropertyLevelCalendarIfApplicable: false
          }
        });
        const calendar = data?.merlin?.pdpAvailabilityCalendar;
        if (!Array.isArray(calendar?.calendarMonths))
          throw new Error(`Airbnb availability for stay ${listingId} is unavailable`);
        const calendarMonths = calendar.calendarMonths.map((calendarMonth) => ({
          month: `${calendarMonth?.year}-${String(calendarMonth?.month).padStart(2, "0")}`,
          days: (calendarMonth?.days ?? []).map((day) => ({
            date: scalarText(day?.calendarDate),
            available: Boolean(day?.available),
            availableForCheckIn: Boolean(day?.availableForCheckin),
            availableForCheckOut: Boolean(day?.availableForCheckout),
            minNights: Number(day?.minNights) || 0,
            maxNights: Number(day?.maxNights) || 0,
            priceText: day?.price?.localPriceFormatted ? scalarText(day.price.localPriceFormatted) : null
          }))
        }));
        log(`getStayAvailability ${listingId}: ${calendarMonths.length} months`);
        return { id: listingId, months: calendarMonths };
      }
    });
    action("listStayReviews", {
      async invoke({ id, cursor, limit = 24 } = {}) {
        const listingId = stayId(id);
        const offset = cursor ? Number.parseInt(cursor, 10) : 0;
        if (!Number.isFinite(offset) || offset < 0)
          throw new Error("Invalid review cursor");
        const data = await graphGet("StaysPdpReviewsQuery", HASHES.stayReviews, {
          id: btoa(`StayListing:${listingId}`),
          pdpReviewsRequest: {
            fieldSelector: "for_p3_translation_only",
            forPreview: false,
            limit,
            offset: String(offset),
            showingTranslationButton: false,
            first: limit,
            sortingPreference: "BEST_QUALITY",
            amenityFilters: null
          }
        });
        const reviews = data?.presentation?.stayProductDetailPage?.reviews;
        const items = (reviews?.reviews ?? []).map((review) => ({
          id: String(review?.id ?? ""),
          rating: Number(review?.rating) || 0,
          comments: scalarText(review?.localizedCommentV2?.comments ?? review?.comments),
          language: scalarText(review?.localizedCommentV2?.commentsLanguage ?? review?.language),
          createdAt: scalarText(review?.createdAt),
          localizedDate: scalarText(review?.localizedDate),
          reviewerName: scalarText(review?.reviewer?.firstName),
          reviewerLocation: scalarText(review?.localizedReviewerLocation),
          reviewerPhotoUrl: review?.reviewer?.pictureUrl ? String(review.reviewer.pictureUrl) : null,
          response: review?.localizedCommentV2?.response || review?.response ? scalarText(review?.localizedCommentV2?.response ?? review?.response) : null
        }));
        const total = Number(reviews?.metadata?.reviewsCount);
        const nextOffset = offset + items.length;
        const nextCursor = items.length && Number.isFinite(total) && nextOffset < total ? String(nextOffset) : null;
        log(`listStayReviews ${listingId} offset ${offset}: ${items.length} reviews`);
        return { items, nextCursor };
      }
    });
    action("getPaymentUrl", {
      async invoke(args = {}) {
        const listingId = stayId(args.listingId);
        const checkIn = dateValue(args.checkIn, "checkIn");
        const checkOut = dateValue(args.checkOut, "checkOut");
        if (checkOut <= checkIn)
          throw new Error("checkOut must be after checkIn");
        const params = new URLSearchParams({
          checkin: checkIn,
          checkout: checkOut,
          guestCurrency: scalarText(args.currency || "USD").toUpperCase(),
          isWorkTrip: String(Boolean(args.isWorkTrip)),
          numberOfAdults: String(args.adults ?? 1),
          numberOfChildren: String(args.children ?? 0),
          numberOfInfants: String(args.infants ?? 0),
          numberOfPets: String(args.pets ?? 0),
          productId: listingId
        });
        localStorage.setItem(ACTIVE_RESERVATION_KEY, transactionKey(args));
        return { url: `${ORIGIN}/book/stays/${encodeURIComponent(listingId)}?${params}` };
      }
    });
    action("getPaymentState", {
      async invoke(args = {}) {
        const key = transactionKey(args);
        const liveConfirmation = location.pathname.match(/^\/book\/confirmation\/stays\/([^/]+)/);
        if (liveConfirmation && localStorage.getItem(ACTIVE_RESERVATION_KEY) === key) {
          const completedAt = localDateTime(new Date);
          const reference = decodeURIComponent(liveConfirmation[1]);
          let completed2 = {};
          try {
            completed2 = JSON.parse(localStorage.getItem(COMPLETED_RESERVATIONS_KEY) ?? "{}");
          } catch {}
          completed2[key] = { reference, completedAt };
          localStorage.setItem(COMPLETED_RESERVATIONS_KEY, JSON.stringify(completed2));
          localStorage.removeItem(ACTIVE_RESERVATION_KEY);
          log(`getPaymentState: confirmed reservation ${reference}`);
          return { status: "completed", reference };
        }
        let completed = {};
        try {
          completed = JSON.parse(localStorage.getItem(COMPLETED_RESERVATIONS_KEY) ?? "{}");
        } catch {}
        const stored = completed[key];
        const since = args.since ? new Date(String(args.since).replace(" ", "T")) : null;
        const storedAt = stored ? new Date(stored.completedAt.replace(" ", "T")) : null;
        if (stored && storedAt && (!since || Number.isNaN(since.getTime()) || storedAt >= since)) {
          return { status: "completed", reference: stored.reference };
        }
        const listingId = stayId(args.listingId);
        if (location.pathname === `/book/stays/${listingId}`)
          return { status: "pending", reference: null };
        return { status: "none", reference: null };
      }
    });
    action("searchServices", {
      async invoke({ query, latitude, longitude, date, cursor, limit = 20 } = {}) {
        const serviceDate = dateValue(date, "date");
        const rawParams = [
          rawParam("center_lat", latitude),
          rawParam("center_lng", longitude),
          rawParam("checkin", serviceDate),
          rawParam("date_picker_type", "calendar"),
          rawParam("location_search", "NEARBY"),
          rawParam("refinement_paths", "/services"),
          rawParam("screen_size", "large"),
          rawParam("search_type", "search_query"),
          rawParam("version", "1.8.8")
        ];
        if (cursor)
          rawParams.push(rawParam("cursor", cursor));
        const data = await graphPost("ServicesSearchQuery", HASHES.servicesSearch, {
          isLeanTreatment: false,
          servicesSearchRequest: {
            source: "structured_search_input_header",
            metadataOnly: false,
            treatmentFlags: ["m13_search_input_phase2_treatment", "m13_search_input_services_enabled"],
            rawParams
          }
        });
        const results = data?.presentation?.servicesSearch?.results;
        const found = [];
        const seen = new Set;
        const visit = (value) => {
          if (!value || typeof value !== "object")
            return;
          if (Array.isArray(value)) {
            value.forEach(visit);
            return;
          }
          if (value.__typename === "ServiceSearchResult" && value.listing?.id) {
            const id = numericId(String(value.listing.id));
            if (!seen.has(id)) {
              seen.add(id);
              found.push(value);
            }
            return;
          }
          Object.values(value).forEach(visit);
        };
        visit(results);
        const needle = scalarText(query).toLowerCase();
        const items = found.map((service) => {
          const listing = service.listing;
          const name = scalarText(listing?.descriptions?.name?.localizedValue?.localizedStringWithTranslationPreference);
          const description = scalarText(listing?.descriptions?.byline?.localizedValue?.localizedString);
          const category = scalarText(listing?.themes?.primaryTheme?.themeCategoryConfig?.localizedTitle);
          const rating = listing?.listingRatingStats?.overallRatingStats;
          const id = numericId(String(listing?.id ?? ""));
          return {
            id,
            url: `${ORIGIN}/services/${encodeURIComponent(id)}`,
            name,
            category,
            description,
            location: scalarText(service?.displayLocation),
            priceText: scalarText(service?.displayPrice?.primaryLine?.accessibilityLabel),
            secondaryPriceText: service?.displayPrice?.secondaryLine?.accessibilityLabel ? scalarText(service.displayPrice.secondaryLine.accessibilityLabel) : null,
            rating: Number.isFinite(Number(rating?.ratingAverage)) ? Number(rating.ratingAverage) : null,
            reviewCount: Number.isFinite(Number(rating?.ratingCount)) ? Number(rating.ratingCount) : null,
            yearsOfExperience: Number.isFinite(Number(listing?.yearsOfExperience)) ? Number(listing.yearsOfExperience) : null,
            imageUrl: service?.picture?.picture ? String(service.picture.picture) : null
          };
        }).filter((service) => !needle || `${service.name} ${service.category} ${service.description}`.toLowerCase().includes(needle)).slice(0, limit);
        log(`searchServices ${scalarText(query)}: ${items.length} results`);
        return { items, nextCursor: results?.paginationInfo?.nextPageCursor ?? null };
      }
    });
    action("listTrips", {
      async invoke({ kind = "upcoming", cursor, limit = 10 } = {}) {
        const operationName = kind === "past" ? "PastTripsListQuery" : "TripListQuery";
        const hash = kind === "past" ? HASHES.pastTrips : HASHES.upcomingTrips;
        const variables = kind === "past" ? { first: limit } : {};
        if (cursor)
          variables.after = cursor;
        const data = await graphGet(operationName, hash, variables);
        const trips = data?.viewer?.trips;
        if (!trips)
          throw new Error("Airbnb trips are unavailable. Sign in and retry.");
        const items = (trips?.edges ?? []).map((edge) => tripRow(edge?.node));
        const pageInfo = trips?.pageInfo ?? {};
        log(`listTrips ${kind}: ${items.length} trips`);
        return {
          items,
          nextCursor: pageInfo?.hasNextPage ? pageInfo?.endCursor ?? null : null
        };
      }
    });
    action("getTrip", {
      async invoke({ id } = {}) {
        const graphId = tripGraphId(id);
        const data = await graphGet("TripDetailsQuery", HASHES.tripDetails, { tripId: graphId });
        const trip = data?.node;
        if (!trip?.id)
          throw new Error(`Airbnb trip ${JSON.stringify(id)} was not found`);
        const scheduled = trip?.scheduledItems?.edges?.[0]?.node;
        const reservation = scheduled?.details?.stayReservation;
        const supply = reservation?.supplyListing;
        const rating = supply?.demandListing?.listingRatingStats?.overallRatingStats;
        const location2 = scheduled?.guestFacingLocation;
        const coordinate = location2?.exactCoordinate ?? location2?.obfuscatedCoordinate ?? {};
        const rooms = supply?.roomsAndSpaces ?? {};
        const guests = (reservation?.guests?.edges ?? []).map((edge) => scalarText(edge?.node?.guestUser?.presentation?.displayFirstName)).filter(Boolean);
        const output = {
          id: String(trip.id),
          listingId: supply?.id ? numericId(String(supply.id)) : null,
          name: scalarText(trip?.displayName),
          status: scalarText(trip?.status),
          startTime: scalarText(trip?.startTime?.dateTime),
          endTime: scalarText(trip?.endTime?.dateTime),
          timeZone: scalarText(trip?.startTime?.listingTimeZone),
          address: scalarText(location2?.oneLineAddress),
          latitude: Number.isFinite(Number(coordinate?.latitude)) ? Number(coordinate.latitude) : null,
          longitude: Number.isFinite(Number(coordinate?.longitude)) ? Number(coordinate.longitude) : null,
          confirmationCode: reservation?.confirmationCode ? String(reservation.confirmationCode) : null,
          reservationStatus: reservation?.guestFacingStatus ? String(reservation.guestFacingStatus) : null,
          pendingExpiresAt: reservation?.pendingExpiresAt ? String(reservation.pendingExpiresAt) : null,
          guestCount: Number(reservation?.guestCountDetails?.numberOfAdults) || guests.length,
          guestNames: guests,
          travelerCount: Number(trip?.travelers?.pageInfo?.totalCount) || guests.length,
          travelerNames: guests,
          hostName: scalarText(supply?.primaryHostUserProfile?.displayFirstName ?? supply?.primaryHostUser?.displayFirstName),
          bedrooms: Number.isFinite(Number(rooms?.numberOfBedrooms)) ? Number(rooms.numberOfBedrooms) : null,
          beds: Number.isFinite(Number(rooms?.numberOfBeds)) ? Number(rooms.numberOfBeds) : null,
          bathrooms: Number.isFinite(Number(rooms?.numberOfBathrooms)) ? Number(rooms.numberOfBathrooms) : null,
          rating: Number.isFinite(Number(rating?.ratingAverage)) ? Number(rating.ratingAverage) : null,
          reviewCount: Number.isFinite(Number(rating?.ratingCount)) ? Number(rating.ratingCount) : null,
          imageUrl: supply?.media?.defaultMediaEntity?.uri ? String(supply.media.defaultMediaEntity.uri) : null,
          url: `${ORIGIN}/trips/v1/${encodeURIComponent(numericId(String(trip.id)))}`,
          messageUrl: reservation?.bookingSession?.threadId ? `${ORIGIN}/messaging/threads/${encodeURIComponent(String(reservation.bookingSession.threadId))}` : null
        };
        log(`getTrip ${numericId(String(trip.id))}: ${output.status}`);
        return output;
      }
    });
    action("listWishlists", {
      async invoke({ cursor, limit = 12 } = {}) {
        const offset = cursor ? Number.parseInt(cursor, 10) : 0;
        if (!Number.isFinite(offset) || offset < 0)
          throw new Error("Invalid wishlist cursor");
        const data = await graphGet("WishlistIndexPageQuery", HASHES.wishlists, {
          networkCacheVersion: 1,
          limit,
          offset,
          treatmentFlags: ["wishlist_should_load_service"]
        });
        const wishlists = data?.presentation?.wishlistIndexPage?.wishlists;
        if (!Array.isArray(wishlists))
          throw new Error("Airbnb wishlists are unavailable. Sign in and retry.");
        const items = wishlists.map((wishlist) => {
          const products = wishlist?.productIds ?? {};
          const stayIds = [...new Set((products?.stayIds ?? []).map((value) => numericId(String(value))))];
          const experienceIds = [...new Set((products?.experienceIds ?? []).map((value) => numericId(String(value))))];
          const placeIds = [...new Set([
            ...products?.placeIds ?? [],
            ...products?.airbnbCanonicalPlaceIds ?? []
          ].map(String))];
          const productIds = [
            ...stayIds,
            ...experienceIds,
            ...placeIds
          ];
          const guestDetails = wishlist?.guestDetails ?? {};
          const id = numericId(String(wishlist?.id ?? ""));
          return {
            id: String(wishlist?.id ?? ""),
            name: scalarText(wishlist?.name),
            url: `${ORIGIN}/wishlists/${encodeURIComponent(id)}`,
            itemCount: new Set(productIds.map(String)).size,
            guestCount: Number(wishlist?.guestCount) || 0,
            adults: Number(guestDetails?.numberOfAdults) || 0,
            children: Number(guestDetails?.numberOfChildren) || 0,
            infants: Number(guestDetails?.numberOfInfants) || 0,
            stayIds,
            experienceIds,
            placeIds,
            checkIn: wishlist?.dateRangeDetails?.checkIn ? String(wishlist.dateRangeDetails.checkIn) : null,
            checkOut: wishlist?.dateRangeDetails?.checkOut ? String(wishlist.dateRangeDetails.checkOut) : null,
            private: Boolean(wishlist?.isPrivate),
            collaborative: Boolean(wishlist?.isCollaborative),
            ownerName: scalarText(wishlist?.wishlistUser?.contextualUser?.displayFirstName),
            collaboratorNames: [...new Set((wishlist?.collaboratorUsers ?? []).map((user) => scalarText(user?.contextualUser?.displayFirstName)).filter(Boolean))],
            imageUrl: wishlist?.xlImageUrl ? String(wishlist.xlImageUrl) : null
          };
        });
        log(`listWishlists offset ${offset}: ${items.length} wishlists`);
        return {
          items,
          nextCursor: items.length === limit ? String(offset + items.length) : null
        };
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

  installService("www.airbnb.com", actions_default);
})();
