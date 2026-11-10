const pageCursor = (value, firstPage) =>
  Math.max(firstPage, Number.parseInt(value ?? String(firstPage), 10) || firstPage);

const retryFetch = async (input, init, options) => {
  const retries = options?.retries ?? 3;
  const delay = options?.delay ?? 400;
  const factor = options?.factor ?? 2;
  for (let attempt = 0; ; attempt++) {
    try {
      const response = await window.fetch(input, init);
      const retryable = response.status === 408 || response.status === 429
        || (response.status >= 500 && response.status <= 599);
      if (response.ok || !retryable || attempt >= retries) return response;
      console.log(`retryFetch: status ${response.status}, attempt ${attempt + 1}/${retries}`);
    } catch (error) {
      const message = String(error?.message ?? "");
      const retryable = message.includes("Load failed")
        || message.includes("NetworkError")
        || message.includes("Failed to fetch");
      if (!retryable || attempt >= retries) throw error;
      console.log(`retryFetch: network ${JSON.stringify(message)}, attempt ${attempt + 1}/${retries}`);
    }
    await new Promise(resolve => setTimeout(resolve, delay * Math.pow(factor, attempt)));
  }
};

window.ox.install(({ action }) => {
    const START_URL = "https://secure.chase.com/web/auth/nav?navKey=chaseTravelHome&treatment=chase";
    const EXECUTION_URL = "https://secure.chase.com/robots.txt";
    const GATEWAY = "https://secure.chase.com/svc/wr/profile/l4/gateway/chase-travel/loyalty/bank-rewards/cte-app/v1";
    const uuid = () => "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
        const r = (Math.random() * 16) | 0;
        return (c === "x" ? r : (r & 0x3) | 0x8).toString(16);
    });
    const jpmcHeaders = () => ({
        accept: "application/json",
        "x-jpmc-csrf-token": "NONE",
        "x-jpmc-channel": "id=C30",
        channeltype: "WEB",
        onlineindicator: "true",
        mockindicator: "false",
        "x-jpmc-client-request-id": uuid(),
    });
    const get = async (path) => {
        const r = await retryFetch(`${GATEWAY}${path}`, {
            credentials: "include",
            cache: "no-store",
            headers: jpmcHeaders(),
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
            body: JSON.stringify(body),
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
        const value = values.find((candidate) => typeof candidate === "number"
            || (typeof candidate === "string" && Number.isFinite(Number(candidate))));
        return value === undefined ? null : Number(value);
    };
    const trip = (item) => ({
        id: text(item?.tripId, item?.trip_id, item?.bookingId, item?.id),
        title: text(item?.title, item?.tripName, item?.name),
        type: text(item?.tripType, item?.type, item?.productType),
        status: text(item?.status, item?.bookingStatus),
        startDate: text(item?.startDate, item?.departureDate, item?.checkInDate),
        endDate: text(item?.endDate, item?.returnDate, item?.checkOutDate),
        destination: text(item?.destinationName, item?.destination?.name, item?.destination, item?.location),
    });
    const recentHotelSearch = (item) => {
        const destination = item?.destination ?? item?.dstn ?? item;
        return {
            destination: text(destination?.name, destination?.label, destination?.city, item?.destinationName),
            checkIn: text(item?.checkIn, item?.checkInDate, item?.startDate),
            checkOut: text(item?.checkOut, item?.checkOutDate, item?.endDate),
            payload: JSON.stringify(destination),
        };
    };
    const recentFlightSearch = (item) => ({
        origin: text(item?.origin?.name, item?.originName, item?.origin, item?.from),
        destination: text(item?.destination?.name, item?.destinationName, item?.destination, item?.to),
        departureDate: text(item?.departureDate, item?.startDate),
        returnDate: text(item?.returnDate, item?.endDate),
        tripType: text(item?.tripType, item?.type),
    });
    const deal = (item) => ({
        id: text(item?.dealId, item?.id, item?.identifier),
        title: text(item?.title, item?.name, item?.headline),
        description: text(item?.description, item?.summary),
        destination: text(item?.destinationName, item?.destination, item?.location),
        price: amount(item?.price?.amount, item?.price, item?.amount),
        currency: text(item?.price?.currency, item?.currency, item?.currencyCode),
        url: text(item?.url, item?.link, item?.deeplink),
    });
    const hotel = (item) => ({
        id: text(item?.hotelId, item?.propertyId, item?.id),
        name: text(item?.hotelName, item?.name, item?.title),
        location: text(item?.locationName, item?.location, item?.address?.city),
        rating: amount(item?.rating, item?.starRating),
        price: amount(item?.price?.amount, item?.lowestPrice?.amount, item?.price),
        currency: text(item?.price?.currency, item?.lowestPrice?.currency, item?.currency),
        imageUrl: text(item?.imageUrl, item?.image?.url, item?.thumbnailUrl),
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
    const cleanText = value => String(value ?? "").replace(/\s+/g, " ").trim();

const usable = element => {
  if (!element || element.disabled || element.readOnly || element.type === "hidden") return false;
  if (element.closest("[hidden], [aria-hidden='true'], [inert]")) return false;
  const style = getComputedStyle(element);
  return style.display !== "none" && style.visibility !== "hidden";
};

const waitForStep = async (detectors, timeout = 15000) => {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    for (const [kind, detect] of Object.entries(detectors)) {
      const match = detect();
      if (match) return { kind, match };
    }
    await new Promise(resolve => setTimeout(resolve, 200));
  }
  return { kind: "unknown", match: null };
};

const typeInto = (field, value) => {
  field.focus();
  field.select?.();
  if (!document.execCommand("insertText", false, value) || field.value !== value) {
    Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value").set.call(field, value);
    field.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: value }));
  }
  field.dispatchEvent(new Event("change", { bubbles: true }));
};

const pageError = (root = document) => [...root.querySelectorAll("[role='alert'], [aria-live='assertive'], [aria-live='polite']")]
  .filter(usable)
  .map(element => cleanText(element.innerText))
  .filter(Boolean)
  .join(" | ")
  .slice(0, 200);
const chaseLoginStep=async()=>waitForStep({challenge:()=>[...document.querySelectorAll('input[autocomplete="one-time-code"],iframe[src*="captcha"]')].find(usable),credentials:()=>{const username=document.getElementById('userId-text-input-field'),password=document.getElementById('password-text-input-field'),submit=document.getElementById('signin-button'),root=username?.closest('form');return usable(username)&&usable(password)&&usable(submit)&&root?.contains(password)&&root?.contains(submit)?{username,password,submit,root}:null;}});
action('login',{async invoke(input,context){const step=await chaseLoginStep();if(step.kind==='unknown'&&!input?.account)throw Error('Chase sign-in controls did not become ready; automatic sign-in stopped.');if(step.kind!=='credentials')return null;if(!input?.account||input.account.serviceID!=='web:chase.com')return null;if(pageError(step.match.root))throw Error('Chase sign-in reports an error; stopped without retrying.');const account=await context.secret(input.account);typeInto(step.match.username,account.username);typeInto(step.match.password,account.password);if(!usable(step.match.submit))throw Error('Chase sign-in button unavailable.');step.match.submit.click();return null;}});
const discoverAuthenticatedSessions = async () => {
            if(location.hostname==='travelsecure.chase.com'){const r=await fetch('/api/orxe/v1.0/user/profile',{credentials:'include',cache:'no-store'});if(r.status===401)return [];if(!r.ok)throw Error('Booking profile HTTP '+r.status);const j=await r.json();if(!j.profile?.ownerId||!j.profile?.id)throw Error('Booking identity unavailable');return [{id:'booking:'+j.profile.ownerId,label:'Chase Travel booking profile',url:'https://secure.chase.com/web/auth/dashboard#/dashboard/travel'}];}
            accountsCache = null;
            let j;
            try {
                j = await get('/travel-profiles?all-accounts-hidden-indicator=true');
            } catch (error) {
                if (error?.message === 'GET /travel-profiles HTTP 401')
                    return [];
                throw error;
            }
            if (!j?.onlineProfileIdentifier)
                throw Error('Chase Travel account identity unavailable');
            const booking=await get('/proxy/api/orxe/v1.0/user/profile');if(!booking.profile?.ownerId||!booking.profile?.id)throw Error('Chase-to-Travel identity mapping unavailable');return [{id:'booking:'+booking.profile.ownerId,label:'Chase Travel booking profile',url:'https://secure.chase.com/web/auth/dashboard#/dashboard/travel'}];

    };
    action('listSessions', { invoke: discoverAuthenticatedSessions });
    action("getTravelProfile", {
        async invoke() {
            try {
                accountsCache = null;
                const j = await get("/travel-profiles?all-accounts-hidden-indicator=true");
                const accts = Array.isArray(j?.accounts) ? j.accounts : [];
                accountsCache = accts;
                console.log(`getTravelProfile: ${accts.length} accounts`);
                return {
                    loyaltyProfileIdentifier: text(j?.loyaltyProfileIdentifier),
                    enterprisePartyIdentifier: text(j?.enterprisePartyIdentifier),
                    onlineProfileIdentifier: text(j?.onlineProfileIdentifier),
                    accounts: accts.map((a) => ({
                        digitalAccountIdentifier: a?.digitalAccountIdentifier ?? null,
                        accountNicknameText: text(a?.accountNicknameText),
                        last4AccountNumber: text(a?.last4AccountNumber),
                        rewardsBalanceAmount: a?.rewardsBalanceAmount ?? null,
                        cardCreditLimitAmount: a?.cardSpendControl?.cardCreditLimitAmount ?? null,
                        availableCreditAmount: a?.cardSpendControl?.availableCreditAmount ?? null,
                    })),
                };
            }
            catch (e) {
                console.log("getTravelProfile: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });
    action("getStatementCredits", {
        async invoke({ digitalAccountIdentifier } = {}) {
            try {
                const id = digitalAccountIdentifier ?? (await primaryAccountId());
                if (id == null)
                    throw new Error("no digitalAccountIdentifier available");
                const j = await get(`/statement-credits?digital-account-identifier=${id}`);
                const credits = Array.isArray(j?.statementCredits) ? j.statementCredits : [];
                console.log(`getStatementCredits: account=${id} total=${j?.availableStatementCreditAmount ?? "?"} count=${credits.length}`);
                return {
                    availableStatementCreditAmount: j?.availableStatementCreditAmount ?? null,
                    rewardsAnniversaryDate: j?.rewardsAnniversaryDate ?? null,
                    statementCredits: credits.map((credit) => ({
                        id: text(credit?.creditId, credit?.id, credit?.identifier),
                        name: text(credit?.creditName, credit?.name, credit?.title),
                        description: text(credit?.description, credit?.details),
                        availableAmount: amount(credit?.availableAmount, credit?.remainingAmount, credit?.amount),
                        usedAmount: amount(credit?.usedAmount, credit?.redeemedAmount),
                        expirationDate: text(credit?.expirationDate, credit?.endDate, credit?.renewalDate),
                    })),
                };
            }
            catch (e) {
                console.log("getStatementCredits: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });
    action("listTrips", {
        async invoke({ tripType, cursor, limit } = {}) {
            try {
                const pn = pageCursor(cursor, 1);
                const ps = limit ?? 50;
                const j = await get(`/proxy/api/mytrip/v1.0/native/trip?pagenumber=${pn}&pagesize=${ps}&tripType=${tripType ?? "Upcoming"}`);
                const items = firstArray(j, ["trips", "items", "results"]).map(trip);
                console.log(`listTrips: ${items.length} trips (${tripType ?? "Upcoming"} page ${pn})`);
                return { items, nextCursor: nextCursor(items, pn, ps) };
            }
            catch (e) {
                console.log("listTrips: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });
    action("listRecentHotelSearches", {
        async invoke() {
            try {
                const j = await get("/hotel/search/recent");
                const items = firstArray(j, ["s", "searches", "items", "results"]).map(recentHotelSearch);
                console.log(`listRecentHotelSearches: ${items.length} items`);
                return { items, nextCursor: null };
            }
            catch (e) {
                console.log("listRecentHotelSearches: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });
    action("listRecentFlightSearches", {
        async invoke() {
            try {
                const j = await get("/flight/search/recent");
                const items = firstArray(j, ["locations", "searches", "items", "results"]).map(recentFlightSearch);
                console.log(`listRecentFlightSearches: ${items.length} items`);
                return { items, nextCursor: null };
            }
            catch (e) {
                console.log("listRecentFlightSearches: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });
    action("listDeals", {
        async invoke({ cursor, limit } = {}) {
            try {
                const pn = pageCursor(cursor, 1);
                const ps = limit ?? 20;
                const j = await get(`/proxy/api/orxe/v1.0/deals/dealFinder?searchCriteria.campaignId=blt6eba58b817284826` +
                    `&searchCriteria.identifier=dealList&pagination.pageNumber=${pn}&pagination.pageSize=${ps}`);
                const items = firstArray(j, ["deals", "items", "results"]).map(deal);
                console.log(`listDeals: ${items.length} deals (page ${pn})`);
                return { items, nextCursor: nextCursor(items, pn, ps) };
            }
            catch (e) {
                console.log("listDeals: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });
    action("searchHotels", {
        async invoke({ destination, checkIn, checkOut, adults, currency, cursor, limit }) {
            try {
                const cur = currency || "USD";
                const rawDestination = typeof destination?.payload === "string"
                    ? JSON.parse(destination.payload)
                    : destination;
                const created = await post("/proxy/api/hotel/v1.0/search", {
                    cur,
                    sq: {
                        sp: { e: `${checkOut}T00:00:00`, s: `${checkIn}T00:00:00` },
                        dstn: rawDestination,
                        g: { adt: adults ?? 1, ca: [] },
                        st: "hotels",
                        ftr: null,
                    },
                });
                const sid = created?.sid ?? created?.searchId ?? created?.sessionId ?? created?.id ??
                    created?.data?.sid ?? null;
                console.log(`searchHotels: created sid=${sid ?? "?"} keys=${Object.keys(created ?? {}).join(",")}`);
                if (!sid)
                    throw new Error("no search session id in create response");
                const pn = pageCursor(cursor, 1);
                const ps = limit ?? 16;
                const j = await post("/proxy/api/hotel/v1.0/search/results", {
                    cur,
                    ftr: {
                        b: [], cn: [], hids: [], hs: [], idoh: false, rt: [], tar: [], tyr: [],
                        amn: [], p: { max: null, min: null }, nh: [], rfd: [], pt: [],
                        cf: null, bo: null, bd: [], bt: [], gr: [],
                    },
                    pg: { pn, ps, tr: null },
                    sid,
                    sb: "boolSortfield1 desc, numberSortfield1 asc, recommendation",
                    lm: null,
                });
                const items = firstArray(j, ["h", "hotels", "results", "items", "data"]).map(hotel);
                console.log(`searchHotels: ${items.length} hotels (page ${pn})`);
                return { sid, items, nextCursor: nextCursor(items, pn, ps) };
            }
            catch (e) {
                console.log("searchHotels: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });
    action("getCartCount", {
        async invoke() {
            try {
                const j = await get("/checkout/cartcount");
                console.log(`getCartCount: ${j?.totalItems ?? j?.numberOfItems ?? "?"}`);
                return {
                    numberOfItems: j?.numberOfItems ?? null,
                    numberOfAddOnItems: j?.numberOfAddOnItems ?? null,
                    totalItems: j?.totalItems ?? null,
                };
            }
            catch (e) {
                console.log("getCartCount: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });

    action('getRoundTripOptions', { async invoke(args) {
        const sessions=await discoverAuthenticatedSessions();if(sessions.length!==1)throw Error('A single authenticated Chase account is required.');const session=sessions[0];
        const profile = await get('/travel-profiles?all-accounts-hidden-indicator=true');
        if (!session || !profile.onlineProfileIdentifier) throw Error('Chase account identity unavailable.');
        if(args.returnDate <= args.departureDate) throw Error('Return must follow departure.');
        const lookup = async (code, allowCity) => {
            const j = await post('/autosuggest/search', {sq:{st:code,sf:['arrival-airport']},sel:false,rec:null,c:'flights'});
            if(!Array.isArray(j.s)) throw Error('Airport lookup response is incomplete.');
            const all=j.s.flatMap(x=>[x,...(x.sl||[])]);
            const x=all.find(x=>x.cd===code && (allowCity ? x.iaa : !x.iaa)) || all.find(x=>x.cd===code);
            if(!x) throw Error('Airport '+code+' was not found.');
            return {code:x.cd,type:x.iaa?'City':'Airport',name:x.n,shortName:x.n,country:x.c,cityName:x.cn,stateCode:x.sc,countryCode:x.cc,locationId:x.lId,timeZone:x.tzi?.tz};
        };
        const from=await lookup(args.origin,false),to=await lookup(args.destination,args.destination==='DFW');
        const created=await post('/flight/search/roundtrip',{currency:'USD',journeys:[{departure:from,arrival:to,travelDate:{date:args.departureDate,timeWindow:0}},{arrival:from,departure:to,travelDate:{date:args.returnDate,timeWindow:0}}],passengers:[{count:1,type:'Adult'}],filters:{connection:{nonStopOnly:true,maximumConnectingPoints:3},airlines:{allow:[],onlineConnectionOnly:false},unrestrictedFaresOnly:false,refundableOnly:false,brandedFares:true,upsell:false,timeFilters:[],excludeBasicEconomy:false},journeyType:'roundtrip',cabinType:'Economy',isMixAndMatch:true});
        if(!created.sessionId)throw Error('Flight search did not return a search identifier.');
        const req={sessionId:created.sessionId,journeyType:'outbound',outBoundFareOptionId:'',paging:{pageSize:args.limit||10,pageNumber:1,orderBy:'recommended'},facets:null,isMixAndMatch:true,comboFares:true,quickSortingOptions:['recommended','price Asc','journeyTime Asc']};
        let j; const deadline=Date.now()+18000;
        do{j=await post('/proxy/api/air/v1.0/search/legwiseResults',req);if(Array.isArray(j.itineraries)&&j.itineraries.length)break;if(/complete|finished/i.test(String(j.status)))break;await new Promise(r=>setTimeout(r,350));}while(Date.now()<deadline);
        if(!Array.isArray(j?.itineraries))throw Error('Flight results schema not available.');
        if(!j.itineraries.length&&!/complete|finished/i.test(String(j.status)))throw Error('Flight results are still loading.');
        const items=j.itineraries.map(i=>{const journey=i.journeys?.[0],segments=journey?.segments||[],first=segments[0]?.flight,last=segments.at(-1)?.flight;if(!first||!last)throw Error('Incomplete flight journey.');return {airline:first.marketingCarrier?.name||first.operatingCarrier?.name||'',departure:first.departure.dateTime,arrival:last.arrival.dateTime,origin:first.departure.airport.code,destination:last.arrival.airport.code,durationMinutes:journey.durationInMinutes,stops:Math.max(0,segments.length-1),fares:(i.fareOptions||[]).filter(f=>typeof f.displayPrice?.total?.payable?.options?.cashOnly?.value==='number').map(f=>({name:f.fareFamily?.name||f.fareCategory||'',cash:f.displayPrice.total.payable.options.cashOnly.value}))};});
        const current=await discoverAuthenticatedSessions();if(current.length!==1||current[0].id!==session.id)throw Error('Chase account changed during search.');
        return {currency:j.currency||'USD',priceBasis:'Starting round-trip fares for outbound choices; return flight selection not yet confirmed.',resultCount:j.resultCount||items.length,status:String(j.status||''),items,nextCursor:null};
    }});
    action('getPairedFlightOptions', { async invoke(args) {
        const sessions=await discoverAuthenticatedSessions();if(sessions.length!==1)throw Error('A single authenticated Chase account is required.');const session=sessions[0];
        const profile = await get('/travel-profiles?all-accounts-hidden-indicator=true');
        if (!session || !profile.onlineProfileIdentifier) throw Error('Chase account identity unavailable.');
        if(args.returnDate <= args.departureDate) throw Error('Return must follow departure.');
        const lookup = async (code, allowCity) => {
            const j = await post('/autosuggest/search', {sq:{st:code,sf:['arrival-airport']},sel:false,rec:null,c:'flights'});
            if(!Array.isArray(j.s)) throw Error('Airport lookup response is incomplete.');
            const all=j.s.flatMap(x=>[x,...(x.sl||[])]);
            const x=all.find(x=>x.cd===code && (allowCity ? x.iaa : !x.iaa)) || all.find(x=>x.cd===code);
            if(!x) throw Error('Airport '+code+' was not found.');
            return {code:x.cd,type:x.iaa?'City':'Airport',name:x.n,shortName:x.n,country:x.c,cityName:x.cn,stateCode:x.sc,countryCode:x.cc,locationId:x.lId,timeZone:x.tzi?.tz};
        };
        const from=await lookup(args.origin,false),to=await lookup(args.destination,args.destination==='DFW');
        const created=await post('/flight/search/roundtrip',{currency:'USD',journeys:[{departure:from,arrival:to,travelDate:{date:args.departureDate,timeWindow:0}},{arrival:from,departure:to,travelDate:{date:args.returnDate,timeWindow:0}}],passengers:[{count:1,type:'Adult'}],filters:{connection:{nonStopOnly:true,maximumConnectingPoints:3},airlines:{allow:[],onlineConnectionOnly:false},unrestrictedFaresOnly:false,refundableOnly:false,brandedFares:true,upsell:false,timeFilters:[],excludeBasicEconomy:false},journeyType:'roundtrip',cabinType:'Economy',isMixAndMatch:true});
        if(!created.sessionId)throw Error('Flight search did not return a search identifier.');
        const req={sessionId:created.sessionId,journeyType:'outbound',outBoundFareOptionId:'',paging:{pageSize:50,pageNumber:1,orderBy:'recommended'},facets:null,isMixAndMatch:true,comboFares:true,quickSortingOptions:['recommended','price Asc','journeyTime Asc']};
        let j; const deadline=Date.now()+18000;
        do{j=await post('/proxy/api/air/v1.0/search/legwiseResults',req);if(Array.isArray(j.itineraries)&&j.itineraries.length)break;if(/complete|finished/i.test(String(j.status)))break;await new Promise(r=>setTimeout(r,350));}while(Date.now()<deadline);
        if(!Array.isArray(j?.itineraries))throw Error('Flight results schema not available.');
        if(!j.itineraries.length&&!/complete|finished/i.test(String(j.status)))throw Error('Flight results are still loading.');

        const chosen=j.itineraries.filter(i=>i.journeys?.[0]?.segments?.length===1).find(i=>{const f=i.journeys[0].segments[0].flight;return f.departure.dateTime.slice(11,16)===args.outboundTime&&(f.marketingCarrier?.name||'').toLowerCase().includes(args.airline.toLowerCase());});
        if(!chosen)throw Error('Requested nonstop outbound was not found.');
        const fare=(chosen.fareOptions||[]).find(f=>f.fareFamily?.name?.toLowerCase()===args.fareName.toLowerCase());if(!fare?.refId)throw Error('Requested outbound fare is unavailable.');
        const inboundReq={...req,journeyType:'inbound',outBoundFareOptionId:fare.refId,paging:{pageSize:50,pageNumber:1,orderBy:'price Asc'}};
        const incoming=await post('/proxy/api/air/v1.0/search/legwiseResults',inboundReq);if(!Array.isArray(incoming.itineraries))throw Error('Paired return results incomplete.');
        const asFlight=i=>{const s=i.journeys[0].segments;const f=s[0].flight,l=s.at(-1).flight;return {departure:f.departure.dateTime,arrival:l.arrival.dateTime,origin:f.departure.airport.code,destination:l.arrival.airport.code,flightNumber:String(f.marketingCarrier?.code||'')+' '+String(f.flightNumber||''),airline:f.marketingCarrier?.name||''};};
        const items=incoming.itineraries.filter(i=>i.journeys?.[0]?.segments?.length===1).filter(i=>asFlight(i).airline.toLowerCase().includes(args.airline.toLowerCase())).flatMap(i=>(i.fareOptions||[]).filter(f=>f.fareFamily?.name?.toLowerCase()===args.fareName.toLowerCase()).map(f=>({flight:asFlight(i),fareName:f.fareFamily.name,cash:f.displayPrice.total.payable.options.cashOnly.value,rawTotal:f.displayFare?.totalAmount??f.displayPrice.total.payable.options.cashOnly.value,mixedFare:!!f.comboFare}))).slice(0,args.limit||30);
        const current=await discoverAuthenticatedSessions();if(current.length!==1||current[0].id!==session.id)throw Error('Chase account changed during pair verification.');
        return {searchId:created.sessionId,outbound:asFlight(chosen),outboundFare:fare.fareFamily.name,currency:incoming.currency||'USD',items,nextCursor:null,resultCount:incoming.resultCount||items.length,status:String(incoming.status||'')};
    }});

    action('prepareFlightCart',{async invoke(args){
        const all=()=>{const roots=[document],elements=[];for(let i=0;i<roots.length&&i<900;i++)for(const e of roots[i].querySelectorAll('*')){elements.push(e);if(e.shadowRoot)roots.push(e.shadowRoot);}return elements;};
        const visible=e=>{if(!e||e.disabled||e.hasAttribute('disabled'))return false;const s=getComputedStyle(e);return s.display!=='none'&&s.visibility!=='hidden'&&s.opacity!=='0'&&!e.closest('[hidden],[aria-hidden="true"],[inert]');};
        const text=e=>(e.innerText||e.textContent||'').replace(/\s+/g,' ').trim();
        const wait=async(test,label,ms=18000)=>{const end=Date.now()+ms;while(Date.now()<end){const r=test();if(r)return r;await new Promise(r=>setTimeout(r,150));}throw Error('Flight preparation stopped: '+label+' not ready. Route '+location.pathname+'; cards '+document.querySelectorAll('orxe-flight-itinerary-card').length+'; modal '+Boolean(document.querySelector('orxe-desktop-create-overlay'))+'; visible steps '+all().filter(e=>e.tagName==='ORXE-BUTTON'&&visible(e)&&text(e)&&text(e).length<45).map(text).slice(-12).join(' | ')+'. No payment submitted.');};
        const click=e=>{if(!visible(e))throw Error('Requested control is unavailable');const inner=e.shadowRoot?.querySelector('button');(inner||e).click();};
        const button=label=>all().find(e=>e.tagName==='ORXE-BUTTON'&&visible(e)&&text(e).toLowerCase()===label.toLowerCase());
        const time=t=>{const [h,m]=t.split(':').map(Number);return String(h%12||12).padStart(2,'0')+':'+String(m).padStart(2,'0')+' '+(h<12?'am':'pm');};
        const card=t=>[...document.querySelectorAll('orxe-flight-itinerary-card')].find(e=>text(e).toLowerCase().includes(args.airline.toLowerCase())&&text(e).toLowerCase().includes('departure time is '+time(t)));
        const selectFare=async t=>{const c=await wait(()=>card(t),'requested flight');const b=[...c.querySelectorAll('[role=button]')].find(e=>text(e).toLowerCase()===args.fareName.toLowerCase());if(!b)throw Error('Requested fare is not offered');click(b);};
        const countResponse=await fetch('/api/checkout-bff/v1.0/cart/itemCount',{credentials:'include',cache:'no-store'});if(!countResponse.ok)throw Error('Could not check cart before selecting flights');const counts=await countResponse.json();const count=counts.totalItems??counts.numberOfItems??counts.itemCount??counts.count; if(count!==0)throw Error('An existing or unclassified cart must be reviewed before adding another itinerary. No cart changes made.');
        await wait(()=>location.pathname==='/results/flights/outbound'&&document.querySelector('orxe-flight-itinerary-card'),'outbound flight results');
        await selectFare(args.outboundTime);click(await wait(()=>button('Choose flight'),'outbound choose-flight button'));
        const upsell=()=>{const o=document.querySelector('orxe-desktop-create-overlay');return o&&text(o).includes('Upgrade for more flexibility')&&text(o).includes(args.fareName)&&text(o).includes('Selected')&&button('Continue');};
        const outboundNext=await wait(()=>location.pathname==='/results/flights/inbound'?'inbound':upsell(),'outbound fare continuation');if(outboundNext!=='inbound')click(outboundNext);
        await wait(()=>location.pathname==='/results/flights/inbound'&&document.querySelector('orxe-flight-itinerary-card'),'return flight results');
        await selectFare(args.returnTime);const add=await wait(()=>button('Add to trip'),'fare review add-to-trip button');
        const overlay=document.querySelector('orxe-desktop-create-overlay');const roots=[overlay];const leaves=[];for(let i=0;i<roots.length&&i<150;i++){if(!roots[i])continue;for(const e of roots[i].querySelectorAll('*')){if(e.shadowRoot)roots.push(e.shadowRoot);if(!e.children.length&&visible(e)&&text(e))leaves.push(text(e));}}
        const idx=leaves.findIndex(t=>t==='Flight total');const displayed=idx<0?NaN:Number((leaves.slice(idx+1).find(t=>/^\$[\d,]+/.test(t))||'').replace(/[^0-9.]/g,''));if(!Number.isFinite(displayed)||displayed>args.maximumCash)throw Error('Flight total exceeds the authorized price cap or is unavailable. Nothing added.');
        if(leaves.filter(t=>t.toLowerCase()===args.fareName.toLowerCase()).length<2)throw Error('Both flights are not confirmed in the requested fare. Nothing added.');
        click(add);
        let stage=await wait(()=>{if(upsell())return 'fareContinuation';if(location.pathname.includes('checkout'))return 'checkout';const e=all().find(e=>visible(e)&&/^(view trip|view cart|checkout|check out|continue to checkout|go to checkout)$/i.test(text(e)));return e?'cartAdded':null;},'cart-add outcome',20000);
        if(stage==='fareContinuation'){click(upsell());stage=await wait(()=>{if(location.pathname.includes('checkout'))return 'checkout';return all().some(e=>visible(e)&&/^(view trip|view cart|checkout|check out|continue to checkout|go to checkout)$/i.test(text(e)))?'cartAdded':null;},'Saver cart-add outcome',20000);}
        const elements=all().filter(visible);return {stage,path:location.pathname,summary:leaves.slice(-45),controls:elements.filter(e=>e.matches('orxe-button,button,a')&&text(e)&&text(e).length<70).map(text).filter((x,i,a)=>a.indexOf(x)===i).slice(-25),orderSubmitted:false};
    }});

    action('prepareFlightReview',{async invoke(args){
      const elements=()=>{const r=[document],a=[];for(let i=0;i<r.length&&i<1000;i++)for(const e of r[i].querySelectorAll('*')){a.push(e);if(e.shadowRoot)r.push(e.shadowRoot);}return a;};
      const visible=e=>{const s=getComputedStyle(e);return !e.disabled&&!e.hasAttribute('disabled')&&s.display!=='none'&&s.visibility!=='hidden'&&s.opacity!=='0'&&!e.closest('[hidden],[aria-hidden="true"],[inert]');};
      const text=e=>(e.innerText||e.textContent||'').replace(/\s+/g,' ').trim();
      const wait=async(fn,ms=20000)=>{const end=Date.now()+ms;while(Date.now()<end){const x=fn();if(x)return x;await new Promise(r=>setTimeout(r,150));}throw Error('Checkout readiness could not be established; no payment was submitted.');};
      const start=await wait(()=>elements().find(e=>{if(e.tagName!=='ORXE-BUTTON'||!visible(e)||text(e)!=='Start checkout')return false;const b=e.shadowRoot?.querySelector('button')||e,s=getComputedStyle(b),r=b.getBoundingClientRect();return !b.disabled&&parseFloat(s.fontSize)>=12&&r.width>=20&&r.height>=20&&s.color!==s.backgroundColor;}));
      const r=await fetch('/api/checkout-bff/v1.0/cart/itemCount',{credentials:'include',cache:'no-store'});if(!r.ok)throw Error('Cart verification failed');const count=await r.json();if(count.totalItems!==1||count.numberOfAddOnItems!==0)throw Error('Cart has unexpected items; stopped before checkout.');
      let leaves;await wait(()=>{leaves=elements().filter(e=>!e.children.length&&visible(e)).map(text).filter(Boolean);const i=leaves.indexOf('Amount due today:');return leaves.some(t=>t.includes(args.outboundFlight))&&leaves.some(t=>t.includes(args.returnFlight))&&i>=0&&/\$\s*[1-9][\d,]*(?:\.\d{2})?/.test(leaves.slice(i+1,i+7).join(' '));});
      if(!leaves.some(t=>t.includes(args.outboundFlight))||!leaves.some(t=>t.includes(args.returnFlight)))throw Error('Cart flights do not match request.');
      const date=d=>new Date(d+'T12:00:00Z').toLocaleDateString('en-US',{timeZone:'UTC',weekday:'short',month:'short',day:'numeric',year:'numeric'});
      if(!leaves.some(t=>t.includes(date(args.departureDate))&&t.includes(args.fareName))||!leaves.some(t=>t.includes(date(args.returnDate))&&t.includes(args.fareName)))throw Error('Cart dates or fare brands do not match.');
      const idx=leaves.indexOf('Amount due today:');const priceText=leaves.slice(idx+1,idx+7).join(' ');const priceMatch=priceText.match(/\$\s*([\d,]+(?:\.\d{2})?)/);const amount=priceMatch?Number(priceMatch[1].replace(/,/g,'')):NaN;if(idx<0||!Number.isFinite(amount)||amount>args.maximumCash||amount<=0)throw Error('Cash total changed or is not available. Observed price section: '+(idx<0?'missing':priceText.slice(0,100)));
      (start.shadowRoot?.querySelector('button')||start).click();
      await wait(()=>{const es=elements().filter(visible);return location.pathname!='/checkout/trip-cart/'&&location.pathname!='/checkout/trip-cart'||es.some(e=>e.matches('input,select')&&/traveler|first.?name|last.?name|email/i.test((e.id||'')+' '+(e.name||'')+' '+(e.getAttribute('aria-label')||'')));});
      await wait(()=>elements().some(e=>visible(e)&&e.matches('input,select,orxe-button,button')&&/traveler|first.?name|continue|review|payment|complete|book/i.test((e.id||'')+' '+(e.name||'')+' '+text(e))));
      if(args.travelerName){const next=await wait(()=>{const a=elements();const selected=a.some(e=>e.matches('input')&&(e.getAttribute('aria-label')||'').toLowerCase().includes('traveler profile, '+args.travelerName.toLowerCase()));if(!selected)return null;return a.find(e=>{if(e.tagName!=='ORXE-BUTTON'||text(e)!=='Payment and review'||!visible(e))return false;const b=e.shadowRoot?.querySelector('button')||e,r=b.getBoundingClientRect();return !b.disabled&&r.width>=20&&r.height>=20;});});(next.shadowRoot?.querySelector('button')||next).click();await wait(()=>location.pathname==='/checkout/review-and-pay');await wait(()=>elements().some(e=>visible(e)&&e.matches('button,orxe-button,input')&&/book|pay|card|complete/i.test(text(e)+' '+(e.getAttribute('aria-label')||''))));}
      const es=elements().filter(visible);const controls=es.filter(e=>e.matches('orxe-button,button,a')&&text(e)&&text(e).length<80).map(text).filter((t,i,a)=>a.indexOf(t)===i).slice(-30);
      const fields=es.filter(e=>e.matches('input,select')&&!/hidden|password/.test(e.type||'')).map(e=>({tag:e.tagName,id:e.id||'',name:e.name||'',type:e.type||'',label:e.getAttribute('aria-label')||e.labels?.[0]?.textContent?.trim()||'',required:!!e.required,hasValue:!!e.value}));
      const legible=es.filter(e=>e.matches('button,input,select')).some(e=>{const s=getComputedStyle(e),r=e.getBoundingClientRect();return parseFloat(s.fontSize)>=12&&r.width>=20&&r.height>=20&&s.color!==s.backgroundColor;});
      const reviewUrl=new URL(location.href);for(const key of ['cnxtoken','token','access_token','id_token'])reviewUrl.searchParams.delete(key);return {reviewUrl:reviewUrl.href,path:location.pathname,amount,currency:'USD',controls,fields,readable:legible,orderSubmitted:false};
    }});

 action('prepareFlightPaymentReview',{async invoke(args){
  const elements=()=>{const r=[document],a=[];for(let i=0;i<r.length&&i<1100;i++)for(const e of r[i].querySelectorAll('*')){a.push(e);if(e.shadowRoot)r.push(e.shadowRoot);}return a;};
  const text=e=>(e.innerText||e.textContent||'').replace(/\s+/g,' ').trim();
  const visible=e=>{const s=getComputedStyle(e);return !e.disabled&&!e.hasAttribute('disabled')&&s.display!=='none'&&s.visibility!=='hidden'&&s.opacity!=='0'&&!e.closest('[hidden],[aria-hidden="true"],[inert]');};
  const wait=async(fn)=>{const end=Date.now()+22000;while(Date.now()<end){const v=fn();if(v)return v;await new Promise(r=>setTimeout(r,150));}throw Error('Payment review not ready. No booking or payment submitted.');};
  const next=await wait(()=>elements().find(e=>e.tagName==='ORXE-BUTTON'&&visible(e)&&text(e)==='Payment and review'));
  await wait(()=>elements().some(e=>visible(e)&&e.matches('input')&&(e.getAttribute('aria-label')||'').toLowerCase().includes('traveler profile, '+args.travelerName.toLowerCase())));
  const amountRead=()=>{const leaves=elements().filter(e=>visible(e)&&!e.children.length).map(text);const i=leaves.indexOf('Amount due today:');const match=i<0?null:leaves.slice(i+1,i+7).join(' ').match(/\$\s*([\d,]+(?:\.\d{2})?)/);return match?Number(match[1].replace(/,/g,'')):null;};
  const amount=await wait(()=>{const a=amountRead();return a&&a>0?a:null;});if(amount>args.maximumCash)throw Error('Checkout amount exceeds the authorized cap.');
  (next.shadowRoot?.querySelector('button')||next).click();
  await wait(()=>location.pathname!=='/checkout/traveler-info');
  await wait(()=>elements().some(e=>visible(e)&&e.matches('orxe-button,button,input,select')&&/pay|book|complete|purchase|card|review/i.test(text(e)+' '+(e.getAttribute('aria-label')||''))));
  const es=elements().filter(visible);const controls=es.filter(e=>e.matches('orxe-button,button,a')&&text(e)&&text(e).length<80).map(text).filter((x,i,a)=>a.indexOf(x)===i).slice(-35);
  const readable=es.filter(e=>e.matches('button,input,select')).some(e=>{const s=getComputedStyle(e),r=e.getBoundingClientRect();return parseFloat(s.fontSize)>=12&&r.height>=20&&r.width>=20&&s.color!==s.backgroundColor;});
  return {path:location.pathname,amount:amountRead()||amount,currency:'USD',travelerName:args.travelerName,controls,readable,orderSubmitted:false};
 }});

 action('getFlightCartReview',{async invoke(args){
  const all=()=>{const r=[document],a=[];for(let i=0;i<r.length&&i<1100;i++)for(const e of r[i].querySelectorAll('*')){a.push(e);if(e.shadowRoot)r.push(e.shadowRoot);}return a;};
  const t=e=>(e.innerText||e.textContent||'').replace(/\s+/g,' ').trim();
  const countResponse=await fetch('/api/checkout-bff/v1.0/cart/itemCount',{credentials:'include',cache:'no-store'});if(!countResponse.ok)throw Error('Cart count HTTP '+countResponse.status);const counts=await countResponse.json();if(typeof counts.totalItems!=='number')throw Error('Cart count schema unavailable');if(counts.totalItems===0){const deadline=Date.now()+18000;while(Date.now()<deadline){const message=all().find(e=>!e.children.length&&t(e)==='Your cart is empty');if(message){const s=getComputedStyle(message),r=message.getBoundingClientRect();if(s.display!=='none'&&s.visibility!=='hidden'&&parseFloat(s.fontSize)>=12&&r.width>20&&r.height>10)return {cartItems:0,amount:0,currency:'USD',fareLabels:[],readable:true,checkoutButton:'',cancellation:'',booked:false};}await new Promise(r=>setTimeout(r,150));}throw Error('Cart is empty, but its human-readable view did not become ready.');}const end=Date.now()+25000;let es,leaves,amount,button;
  while(Date.now()<end){es=all();leaves=es.filter(e=>!e.children.length).map(t).filter(Boolean);const idx=leaves.indexOf('Amount due today:');const match=idx<0?null:leaves.slice(idx+1,idx+8).join(' ').match(/\$\s*([\d,]+(?:\.\d{2})?)/);amount=match?Number(match[1].replace(/,/g,'')):null;button=es.find(e=>{if(e.tagName!=='ORXE-BUTTON'||t(e)!=='Start checkout')return false;const b=e.shadowRoot?.querySelector('button')||e;const s=getComputedStyle(b),r=b.getBoundingClientRect();return !b.disabled&&s.display!=='none'&&s.visibility!=='hidden'&&parseFloat(s.fontSize)>=12&&r.width>=20&&r.height>=20&&s.color!==s.backgroundColor;});if(button&&amount>0&&leaves.some(x=>x.includes(args.outboundFlight))&&leaves.some(x=>x.includes(args.returnFlight)))break;await new Promise(r=>setTimeout(r,150));}
  if(!button||!amount||!leaves.some(x=>x.includes(args.outboundFlight))||!leaves.some(x=>x.includes(args.returnFlight)))throw Error('Saved flight cart is not ready for review. No payment or booking was submitted.');if(amount>args.maximumCash)throw Error('Saved cart price exceeds cap.');
  const b=button.shadowRoot?.querySelector('button')||button,s=getComputedStyle(b),r=b.getBoundingClientRect();const readable=!b.disabled&&s.display!=='none'&&s.visibility!=='hidden'&&parseFloat(s.fontSize)>=12&&r.width>=20&&r.height>=20&&s.color!==s.backgroundColor;
  if(!readable)throw Error('Saved cart controls are not legibly rendered.');
  return {cartItems:counts.totalItems,amount,currency:'USD',fareLabels:leaves.filter(x=>/Nov \d+, 20\d{2},/.test(x)),readable,checkoutButton:'Start checkout',cancellation:leaves.find(x=>x.includes('Cancel online for free within 24 hours'))||'',booked:false};
 }});

 action('openTravelCart',{async invoke(){const end=Date.now()+20000;while(Date.now()<end){const b=[...document.querySelectorAll('button')].find(e=>(e.getAttribute('aria-label')||e.innerText||'').trim()==='Trip cart'&&usable(e));if(b){b.click();return {launched:true};}await new Promise(r=>setTimeout(r,150));}throw Error('Authenticated Chase Travel cart launcher is not ready. No cart changes made.');}});

 action('getCheckoutState',{async invoke(){
  const es=()=>{const rs=[document],out=[];for(let i=0;i<rs.length&&i<1100;i++)for(const e of rs[i].querySelectorAll('*')){out.push(e);if(e.shadowRoot)rs.push(e.shadowRoot);}return out;};const txt=e=>(e.innerText||e.textContent||'').replace(/\s+/g,' ').trim();
  const end=Date.now()+10000;while(Date.now()<end){if(es().some(e=>e.matches('orxe-button,button')&&/Payment and review|Complete booking|Book now/i.test(txt(e))))break;await new Promise(r=>setTimeout(r,150));}
  const a=es(),vis=e=>{let n=e;while(n&&n.nodeType===1){const s=getComputedStyle(n);if(s.display==='none'||s.visibility==='hidden'||n.hidden)return false;n=n.parentElement||n.getRootNode()?.host;}return true;};
  return {requestPaths:performance.getEntriesByType('resource').filter(e=>{try{return new URL(e.name).pathname.includes('/api/')||new URL(e.name).pathname.includes('desktop-checkout');}catch{return false;}}).map(e=>{const u=new URL(e.name);return u.pathname+' [HTTP '+(e.responseStatus||'unknown')+']';}).slice(-35),storageKeys:Object.keys(sessionStorage).filter(k=>/cart|travell|checkout|userSession|search-criteria/i.test(k)),path:location.pathname,controls:a.filter(e=>vis(e)&&e.matches('button,orxe-button')&&txt(e)&&txt(e).length<90).map(e=>{const b=e.shadowRoot?.querySelector('button')||e,s=getComputedStyle(b),r=b.getBoundingClientRect();return {tag:e.tagName,label:txt(e),usable:!b.disabled&&vis(b),fontSize:s.fontSize,width:r.width,height:r.height};}).slice(-25),fields:a.filter(e=>vis(e)&&e.matches('input,select')&&!/hidden|password/.test(e.type||'')).map(e=>({id:e.id||'',label:e.getAttribute('aria-label')||e.labels?.[0]?.textContent?.trim()||'',type:e.type||'',hasValue:!!e.value,required:!!e.required,invalid:e.getAttribute('aria-invalid')==='true'})).slice(-30),messages:a.filter(e=>vis(e)&&!e.children.length&&/required|invalid|please|missing|enter |error/i.test(txt(e))&&txt(e).length<180).map(txt).slice(-25),headings:a.filter(e=>vis(e)&&e.matches('h1,h2,h3')).map(txt).filter(Boolean).slice(-15)};
 }});
});
