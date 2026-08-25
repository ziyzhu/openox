const ORIGIN = "https://www.usta.com";
const ACCOUNT = "https://account.usta.com";
const IDP_CLIENT_ID = "HEXVBay49tf4e8kEksXqDCcRNrUjxTM1";
const SERVICES = "https://services.usta.com";
const PLAYTENNIS = "https://playtennis.usta.com";
const SEARCH = "https://prd-usta-kube.clubspark.pro/unified-search-api/api/Search/tournaments/Query?indexSchema=tournament";
window.ox.install(1, ({ action, retryFetch, log }) => {
    const apiJson = async (url, init) => {
        const r = await retryFetch(url, { credentials: "include", ...init });
        const text = await r.text();
        let json;
        try {
            json = text ? JSON.parse(text) : null;
        }
        catch {
            throw new Error(`${url}: non-JSON response (HTTP ${r.status}) — session may have expired`);
        }
        if (!r.ok)
            throw new Error(`${url}: HTTP ${r.status} ${json?.message || ""}`.trim());
        return json;
    };
    const accessToken = () => localStorage.getItem(`access_token_${IDP_CLIENT_ID}`);
    const meJson = (path, init) => {
        const token = accessToken();
        if (!token)
            throw new Error("not signed in (no USTA access token)");
        return apiJson(`${SERVICES}${path}`, {
            ...init,
            credentials: "omit",
            headers: { ...init?.headers, authorization: `Bearer ${token}` },
        });
    };
    const meGet = (path) => meJson(path);
    const mePost = (path, body) => meJson(path, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body ?? {}),
    });
    const text = (...values) => String(values.find((value) => value != null) ?? "");
    const matchRow = (row) => ({
        id: text(row?.id, row?.matchId, row?.eventId),
        date: text(row?.date, row?.startDate, row?.matchDate, row?.eventDate),
        event: text(row?.eventName, row?.event, row?.tournamentName, row?.name),
        opponent: text(row?.opponentName, row?.opponent, row?.teamName),
        result: text(row?.result, row?.outcome, row?.status),
        score: text(row?.score, row?.scoreText),
    });
    action("getSignInUrl", {
        async invoke() {
            const state = `oa${Math.floor(1e3 * Math.random() * Date.now())}`;
            document.cookie = `oauth_state_${IDP_CLIENT_ID}=${state}; path=/`;
            const params = new URLSearchParams({
                scope: "openid offline_access email",
                response_type: "code",
                client_id: IDP_CLIENT_ID,
                redirect_uri: `${ORIGIN}/en/login.html`,
                audience: "usta",
                state,
            });
            const url = `${ACCOUNT}/authorize?${params}`;
            log(`getSignInUrl -> ${url}`);
            return { url };
        },
    });
    action("getSignInState", {
        async invoke() {
            if (!accessToken()) {
                log("getSignInState signedIn=false (no access token)");
                return { signedIn: false };
            }
            try {
                const profile = await meGet("/v1/customers/me");
                const signedIn = Boolean(profile?.uaid || profile?.email);
                log(`getSignInState signedIn=${signedIn}`);
                return { signedIn };
            }
            catch (e) {
                const message = String(e?.message ?? e);
                log(`getSignInState failed (${message})`);
                if (/HTTP (?:401|403)\b/.test(message))
                    return { signedIn: false };
                throw e;
            }
        },
    });
    const geocode = async (q) => {
        const data = await apiJson(`${PLAYTENNIS}/v0/Geocoding/LocationSearch?q=${encodeURIComponent(q)}`);
        return (data?.Places || [])
            .map((p) => ({ label: p.Address || "", latitude: Number(p.Latitude), longitude: Number(p.Longitude) }))
            .filter((p) => Number.isFinite(p.latitude) && Number.isFinite(p.longitude));
    };
    const resolveLatLng = async (args) => {
        const lat = Number(args.latitude);
        const lng = Number(args.longitude);
        if (Number.isFinite(lat) && Number.isFinite(lng))
            return { latitude: lat, longitude: lng };
        const loc = String(args.location ?? "").trim();
        if (!loc)
            throw new Error("provide latitude+longitude or a location to geocode");
        const first = (await geocode(loc))[0];
        if (!first)
            throw new Error(`could not geocode ${JSON.stringify(loc)}`);
        return { latitude: first.latitude, longitude: first.longitude };
    };
    const searchFilters = (distance, startDate, endDate) => [
        { key: "organisation-id", items: [] },
        { key: "location-id", items: [] },
        { key: "region-id", items: [] },
        { key: "publish-target", items: [{ value: 1 }] },
        { key: "level-category", items: [{ value: "" }], operator: "Or" },
        { key: "organisation-group", items: [], operator: "Or" },
        { key: "date-range", items: [{ minDate: startDate, maxDate: endDate }], operator: "Or" },
        { key: "distance", items: [{ value: distance }], operator: "Or" },
        { key: "tournament-status", items: [], operator: "Or" },
        { key: "tournament-level", items: [], operator: "Or" },
        { key: "event-wtn-level", items: [], operator: "Or" },
        { key: "event-division-age-range", items: [], operator: "Or" },
        { key: "event-division-gender", items: [], operator: "Or" },
        { key: "event-ntrp-rating-level", items: [], operator: "Or" },
        { key: "event-division-age-category", items: [], operator: "Or" },
        { key: "event-division-event-type", items: [], operator: "Or" },
        { key: "event-court-location", items: [], operator: "Or" },
        { key: "event-surface", items: [], operator: "Or" },
    ];
    action("searchTournaments", {
        async invoke(args = {}) {
            const { latitude, longitude } = await resolveLatLng(args);
            const size = Math.min(Math.max(Number(args.limit) || 20, 1), 50);
            const from = Number(args.cursor) || 0;
            const distance = Number(args.distanceMiles) || 100;
            const now = new Date();
            const startDate = args.startDate ? new Date(args.startDate).toISOString() : now.toISOString();
            const end = new Date(now);
            end.setMonth(end.getMonth() + 6);
            const endDate = args.endDate ? new Date(args.endDate).toISOString() : end.toISOString();
            const body = {
                options: { size, from, sortKey: "date", latitude, longitude },
                filters: searchFilters(distance, startDate, endDate),
            };
            const data = await apiJson(SEARCH, {
                credentials: "omit",
                headers: { "content-type": "application/json;charset=UTF-8" },
                method: "POST",
                body: JSON.stringify(body),
            });
            const rows = data?.searchResults || [];
            const total = Number(data?.total ?? rows.length);
            const items = rows.map((r) => {
                const t = r.item || {};
                const p = t.primaryLocation || {};
                const place = [t.location?.name, p.town, p.county].filter(Boolean).join(", ");
                return {
                    id: String(t.id ?? ""),
                    name: t.name || "",
                    startDate: t.startDateTime || "",
                    endDate: t.endDateTime || "",
                    location: place,
                    level: t.level?.name || "",
                    url: t.url ? `${PLAYTENNIS}${t.url}` : "",
                };
            });
            const nextCursor = from + rows.length < total && rows.length > 0 ? String(from + size) : null;
            return { items, nextCursor };
        },
    });
    action("getProfile", {
        async invoke() {
            const [me, player] = await Promise.all([
                meGet("/v1/customers/me").catch(() => null),
                meGet("/v1/customers/me/player/profile").catch(() => null),
            ]);
            return {
                id: text(me?.uaid, me?.id, player?.id),
                firstName: text(me?.firstName, player?.firstName),
                lastName: text(me?.lastName, player?.lastName),
                displayName: text(player?.displayName, me?.displayName, [me?.firstName, me?.lastName].filter(Boolean).join(" ")),
                email: text(me?.email),
                city: text(player?.city, me?.city),
                state: text(player?.state, me?.state),
                rating: text(player?.rating, player?.ntrp, player?.wtn),
            };
        },
    });
    action("getMembership", {
        async invoke() {
            const membership = await meGet("/v1/customers/me/membership");
            return {
                memberNumber: text(membership?.memberNumber, membership?.membershipNumber, membership?.ustaNumber),
                type: text(membership?.type, membership?.membershipType, membership?.productName),
                status: text(membership?.status, membership?.membershipStatus),
                startDate: text(membership?.startDate, membership?.effectiveDate),
                expirationDate: text(membership?.expirationDate, membership?.expiryDate, membership?.endDate),
            };
        },
    });
    action("getRankings", {
        async invoke() {
            const data = await mePost("/v1/dataexchange/me/rankings", {});
            const rows = Array.isArray(data) ? data : data?.rankings || data?.items || [];
            return {
                items: rows.map((row) => ({
                    rank: text(row?.rank, row?.ranking),
                    type: text(row?.type, row?.rankingType),
                    division: text(row?.division, row?.divisionName),
                    section: text(row?.section, row?.sectionName),
                    points: text(row?.points, row?.rankingPoints),
                    asOfDate: text(row?.asOfDate, row?.date),
                })),
            };
        },
    });
    action("getPlayHistory", {
        async invoke(args = {}) {
            const pageSize = Math.min(Math.max(Number(args.limit) || 15, 1), 50);
            const currentPage = Number(args.cursor) || 1;
            const data = await mePost("/v1/dataexchange/me/playhistory", {
                selection: { eventType: args.eventType || "ALL", year: args.year || "all" },
                pagination: { pageSize, currentPage },
            });
            const rows = data?.events || data?.matches || data?.results || data?.items || [];
            const totalPages = Number(data?.pagination?.totalPages ?? data?.totalPages ?? 0);
            const nextCursor = currentPage < totalPages ? String(currentPage + 1) : null;
            return { items: rows.map(matchRow), nextCursor };
        },
    });
    action("getSchedule", {
        async invoke({ status } = {}) {
            const s = status === "completed" ? "completed" : "upcoming";
            const data = await meGet(`/v1/dataexchange/schedule/me/${s}`);
            const items = Array.isArray(data) ? data : data?.items || data?.schedule || [];
            return { status: s, items: items.map(matchRow), nextCursor: null };
        },
    });
    log("usta actions installed");
});
