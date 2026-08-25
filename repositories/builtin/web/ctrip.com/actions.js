window.ox.install(1, ({ action, log }) => {
    const BASE_URL = "https://www.ctrip.com/";
    const LOGIN_URL = "https://passport.ctrip.com/user/login";
    const API = "https://m.ctrip.com/restapi/soa2";
    const head = (syscode = "09") => ({
        cid: "09031135417829289144", ctok: "", cver: "1.0",
        lang: "01", sid: "8888", syscode, auth: "", xsid: "", extension: [],
    });
    const postJSON = async (url, body) => {
        const r = await fetch(url, {
            method: "POST",
            credentials: "include",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(body),
        });
        if (!r.ok)
            throw new Error(`${url.split("/").pop()} HTTP ${r.status}`);
        return r.json();
    };
    const parseDate = (v) => {
        const m = String(v ?? "").match(/\/Date\((\d+)/);
        return m ? new Date(+m[1] + 8 * 3600000).toISOString().slice(0, 10) : String(v ?? "");
    };
    const ymd = (d) => `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`;
    const cookie = (name) => (document.cookie.match(new RegExp(`(?:^|; )${name}=([^;]*)`)) || [])[1] || "";
    const gbk = (s) => {
        try {
            const bytes = [];
            for (let i = 0; i < s.length; i++) {
                if (s[i] === "%") {
                    bytes.push(parseInt(s.substr(i + 1, 2), 16));
                    i += 2;
                }
                else
                    bytes.push(s.charCodeAt(i));
            }
            return new TextDecoder("gbk").decode(new Uint8Array(bytes));
        }
        catch {
            return s;
        }
    };
    const hotelHead = () => ({
        platform: "PC", cver: "0", bu: "HBU", group: "ctrip", aid: "1315",
        sid: "1535", locale: "zh-CN", timezone: "-7", currency: "CNY",
        region: "CN", extension: [],
    });
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
    const flightSpaPath = (from, to, date) => `/list/oneway-${from}-${to}?depdate=${date}&cabin=Y_S_C_F&adult=1&child=0&infant=0`;
    const flightRouter = () => {
        if (!/flights\.ctrip\.com/.test(location.href))
            return null;
        return window.next?.router ?? null;
    };
    const dismissFlightModal = () => {
        const btn = Array.from(document.querySelectorAll("button,div,span,a")).find((e) => e.offsetParent && (e.textContent || "").trim() === "我知道了");
        btn?.click();
    };
    const flightPageState = () => {
        dismissFlightModal();
        if (/captcha/.test(location.pathname)
            || /验证码|verify the human|拖动滑块/i.test(document.body?.innerText || ""))
            return "captcha";
        if (document.querySelector(".flight-list > span > div"))
            return "content";
        return "pending";
    };
    const scrapeFlights = () => {
        const clean = (v) => (v || "").replace(/\s+/g, " ").trim();
        const isTime = (s) => /^([01]?\d|2[0-3]):[0-5]\d$/.test(s);
        const isCurrency = (s) => /^[¥$€£]$/.test(s);
        const isPriceDigits = (s) => /^\d+([.,]\d+)?$/.test(s);
        const isFlightNo = (s) => /^[A-Z0-9]{2}\d{3,4}[A-Z]?$/.test(s);
        const items = [];
        document.querySelectorAll(".flight-list > span > div").forEach((card) => {
            const chunks = [];
            const walk = (node) => {
                for (const c of Array.from(node.childNodes)) {
                    if (c.nodeType === 3) {
                        const t = clean(c.textContent || "");
                        if (t)
                            chunks.push(t);
                    }
                    else if (c.nodeType === 1)
                        walk(c);
                }
            };
            walk(card);
            if (chunks.length < 8)
                return;
            const firstTimeIdx = chunks.findIndex(isTime);
            if (firstTimeIdx < 1)
                return;
            const airline = chunks[0];
            const flightNo = chunks[1] || "";
            if (!airline || !isFlightNo(flightNo))
                return;
            const aircraft = chunks[2] && !isTime(chunks[2]) ? chunks[2] : "";
            const depAirport = chunks[firstTimeIdx + 1] || "";
            const arrTimeIdx = chunks.findIndex((c, i) => i > firstTimeIdx && isTime(c));
            if (arrTimeIdx < 0)
                return;
            const skipNextDay = /^\+\d+天$|次日/.test(chunks[arrTimeIdx + 1] || "");
            const arrAirport = chunks[arrTimeIdx + (skipNextDay ? 2 : 1)] || "";
            if (!depAirport || !arrAirport)
                return;
            let price = null;
            for (let i = 0; i < chunks.length - 1; i++) {
                if (isCurrency(chunks[i]) && isPriceDigits(chunks[i + 1])) {
                    price = Number(chunks[i + 1].replace(",", ""));
                    break;
                }
            }
            let cabin = "";
            for (let i = chunks.length - 1; i >= 0; i--) {
                if (/舱$/.test(chunks[i])) {
                    cabin = chunks[i];
                    break;
                }
            }
            items.push({
                airline, flightNo, aircraft,
                departTime: chunks[firstTimeIdx], departAirport: depAirport,
                arriveTime: chunks[arrTimeIdx], arriveAirport: arrAirport,
                price, cabin,
                seatsLeft: Number((chunks.join("").match(/剩(\d+)张/) || [])[1]) || null,
            });
        });
        return items;
    };
    action("getSignInUrl", { async invoke() { return { url: LOGIN_URL }; } });
    action("getSignInState", {
        async invoke() {
            try {
                const signedIn = !!cookie("login_uid");
                log(`getSignInState: login_uid=${signedIn ? "present" : "absent"}`);
                return { signedIn };
            }
            catch (e) {
                log("getSignInState: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });
    action("searchFlightCities", {
        async invoke({ query }) {
            try {
                const j = await postJSON(`${API}/17909/SearchBoxRecommend`, {
                    head: { cver: "3", cid: "", extension: [
                            { name: "source", value: "ONLINE" },
                            { name: "sotpGroup", value: "CTrip" },
                            { name: "sotpLocale", value: "zh-CN" },
                        ] },
                    locale: "zh-CN", departureCity: "", dataType: 1,
                });
                const cities = [];
                for (const g of j?.recommendGroupList ?? []) {
                    const cl = g?.indexedCity?.cityList;
                    if (Array.isArray(cl))
                        cities.push(...cl);
                }
                const q = String(query ?? "").trim().toLowerCase();
                const seen = new Set();
                const items = cities
                    .filter((c) => !q || [c.name, c.nameEn, c.namePy, c.code].some((s) => String(s ?? "").toLowerCase().includes(q)))
                    .filter((c) => c.code && !seen.has(c.code) && seen.add(c.code))
                    .map((c) => ({ code: c.code, name: c.name, nameEn: c.nameEn ?? "" }));
                return { items, nextCursor: null };
            }
            catch (e) {
                log("searchFlightCities: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });
    action("getFlightPriceCalendar", {
        async invoke({ fromCity, toCity, startDate, returnDate }) {
            try {
                const j = await postJSON(`${API}/15380/bjjson/FlightIntlAndInlandLowestPriceSearch`, {
                    departNewCityCode: fromCity, arriveNewCityCode: toCity,
                    searchType: 1, flag: 4, channelName: "FlightOnline",
                    calendarSelections: [{ selectionType: 8, selectionContent: ["15"] }],
                    startDate, returnDate: returnDate ?? startDate, grade: 15,
                    passengerList: [{ passengercount: 1, passengertype: "Adult" }],
                });
                const prices = (j?.priceList ?? []).map((p) => ({
                    departDate: parseDate(p.departDate),
                    returnDate: parseDate(p.returnDate),
                    price: p.price ?? null,
                    totalPrice: p.totalPrice ?? null,
                }));
                return { fromCity, toCity, currency: "CNY", prices };
            }
            catch (e) {
                log("getFlightPriceCalendar: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });
    action("listFlightDeals", {
        async invoke({ fromCity, fromName }) {
            try {
                const now = new Date();
                const end = new Date(now.getTime() + 30 * 86400000);
                const j = await postJSON(`${API}/19728/fuzzySearch`, {
                    tt: 1, source: "online_budget", st: 18,
                    segments: [{
                            dcs: [{ ct: 1, code: fromCity, name: fromName ?? fromCity }],
                            acs: [{ ct: 3, code: "DOMESTIC_ALL", name: "全中国" }],
                            dow: [], sr: null, drl: [{ begin: ymd(now), end: ymd(end) }], ddate: null,
                        }],
                    filters: null, head: head("999"),
                });
                const items = (j?.routes ?? []).map((rt) => {
                    const cheapest = (rt.pl ?? []).reduce((a, b) => (!a || (b.price ?? Infinity) < a.price ? b : a), null);
                    return {
                        destination: rt.arriveCity?.name ?? "",
                        destCode: rt.arriveCity?.code ?? "",
                        image: rt.arriveCity?.imageUrl ?? "",
                        lowestPrice: cheapest?.price ?? null,
                        departDate: cheapest?.departDate ?? "",
                        currency: cheapest?.currency ?? "CNY",
                    };
                }).filter((it) => it.destCode);
                return { items, nextCursor: null };
            }
            catch (e) {
                log("listFlightDeals: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });
    action("searchHotels", {
        async invoke({ cityId, checkIn, checkOut, page }) {
            try {
                const pageIndex = page && page > 0 ? page : 1;
                const j = await postJSON(`${API}/34951/fetchHotelList`, {
                    date: { dateType: 1, dateInfo: {
                            checkInDate: String(checkIn).replace(/-/g, ""),
                            checkOutDate: String(checkOut).replace(/-/g, ""),
                        } },
                    destination: { type: 1, geo: { cityId }, keyword: { word: "" } },
                    roomQuantity: 1,
                    paging: { pageIndex, pageSize: 10 },
                    head: hotelHead(),
                });
                const list = j?.data?.hotelList ?? [];
                const items = list.map((it) => {
                    const h = it.hotelInfo ?? {};
                    const p = it.roomInfo?.[0]?.priceInfo ?? {};
                    const coord = h.positionInfo?.mapCoordinate?.[0] ?? {};
                    return {
                        hotelId: String(h.summary?.hotelId ?? ""),
                        name: h.nameInfo?.name ?? "",
                        nameEn: h.nameInfo?.enName ?? "",
                        star: h.hotelStar?.star ?? null,
                        score: h.commentInfo?.commentScore ?? "",
                        reviews: h.commentInfo?.commenterNumber ?? "",
                        price: typeof p.price === "number" ? p.price : null,
                        displayPrice: p.displayPrice ?? "",
                        address: h.positionInfo?.address ?? "",
                        zone: h.positionInfo?.positionDesc ?? "",
                        image: h.hotelImages?.multiImgs?.[0]?.url ?? "",
                        lat: coord.latitude ?? "",
                        lng: coord.longitude ?? "",
                    };
                }).filter((it) => it.hotelId);
                const nextCursor = items.length >= 10 ? String(pageIndex + 1) : null;
                log(`searchHotels: city=${cityId} page=${pageIndex} -> ${items.length}`);
                return { items, nextCursor };
            }
            catch (e) {
                log("searchHotels: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });
    action("getMemberInfo", {
        async invoke() {
            try {
                const raw = cookie("AHeadUserInfo");
                const field = (k) => (raw.match(new RegExp(`(?:^|&)${k}=([^&]*)`)) || [])[1] || "";
                const info = {
                    signedIn: !!cookie("login_uid"),
                    userName: gbk(field("UserName")),
                    vipGrade: Number(field("VipGrade") || "0"),
                    vipGradeName: gbk(field("VipGradeName")),
                    unreadMessages: Number(field("NoReadMessageCount") || "0"),
                };
                log(`getMemberInfo: grade=${info.vipGrade} signedIn=${info.signedIn}`);
                return info;
            }
            catch (e) {
                log("getMemberInfo: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });
    action("searchFlights", {
        async invoke({ from, to, date }) {
            try {
                const f = String(from).toLowerCase(), t = String(to).toLowerCase();
                const w = window;
                const router = flightRouter();
                if (!router) {
                    throw new Error("Ctrip flight page is unavailable");
                }
                const onTarget = router.asPath?.includes(`oneway-${f}-${t}`) && router.asPath?.includes(`depdate=${date}`);
                if (!onTarget) {
                    log(`searchFlights: router.push ${f}-${t} ${date}`);
                    setTimeout(() => { try {
                        router.push(flightSpaPath(f, t, date));
                    }
                    catch { } }, 50);
                    w.__cflTries = 0;
                    return { items: [], pending: true, note: "" };
                }
                let state = flightPageState();
                for (let i = 0; i < 10 && state !== "content"; i++) {
                    await sleep(1200);
                    state = flightPageState();
                }
                if (state === "captcha")
                    return { items: [], pending: false, note: "Ctrip is showing a captcha — open the Ctrip flight page on screen, complete it, then retry" };
                if (state !== "content") {
                    w.__cflTries = (w.__cflTries || 0) + 1;
                    if (w.__cflTries >= 3)
                        return { items: [], pending: false, note: "no flights rendered — no results or rate-limited" };
                    return { items: [], pending: true, note: "still loading" };
                }
                const items = scrapeFlights();
                log(`searchFlights: ${f}-${t} ${date} -> ${items.length} flights`);
                return { items, pending: false, note: "" };
            }
            catch (e) {
                log("searchFlights: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });
    action("searchHotelCities", {
        async invoke({ query }) {
            try {
                const j = await postJSON(`${API}/34951/getCityList`, {
                    requestType: "5",
                    head: { platform: "PC", cver: "0", cid: "", bu: "HBU", group: "ctrip",
                        aid: "4899", sid: "135371", locale: "zh-CN", region: "CN", currency: "CNY" },
                });
                const cities = [];
                const walk = (o) => {
                    if (!o || typeof o !== "object")
                        return;
                    if (o.displayCityModel && o.basicCityModel) {
                        const d = o.displayCityModel, b = o.basicCityModel;
                        cities.push({
                            cityId: b.cityId,
                            name: d.cityName ?? d.destinationName ?? "",
                            nameEN: d.destinationNameEN ?? "",
                            countryName: d.countryName ?? "",
                        });
                        return;
                    }
                    for (const k of Object.keys(o))
                        walk(o[k]);
                };
                walk(j?.data);
                const q = String(query ?? "").trim().toLowerCase();
                const seen = new Set();
                const items = cities
                    .filter((c) => !q || [c.name, c.nameEN].some((s) => String(s ?? "").toLowerCase().includes(q)))
                    .filter((c) => c.cityId && !seen.has(c.cityId) && seen.add(c.cityId));
                return { items, nextCursor: null };
            }
            catch (e) {
                log("searchHotelCities: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });
});
