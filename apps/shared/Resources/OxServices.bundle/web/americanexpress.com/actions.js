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
    const ORIGIN = "https://www.americanexpress.com";
    const START_URL = `${ORIGIN}/en-us/travel`;
    const LOGIN_URL = `${ORIGIN}/en-us/account/login`;
    const GATEWAY = "https://apigw.americanexpress.com/travel/v2";
    const CLIENT_ID = "684C957199C3BE6C153A778D1986032B";
    const uuid = () => "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
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
    const call = async (path, headers, init) => {
        const r = await retryFetch(`${GATEWAY}${path}`, {
            credentials: "include",
            ...init,
            headers: { ...headers, ...init?.headers },
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
        status: text(item?.status, item?.statusText),
    });
    const trip = (item) => ({
        tripId: text(item?.tripId, item?.trip_id, item?.bookingId, item?.booking_id, item?.id),
        bookingDate: text(item?.bookingDate, item?.booking_date, item?.createdDate, item?.created_at),
        title: text(item?.title, item?.tripName, item?.name),
        type: text(item?.tripType, item?.type, item?.productType),
        status: text(item?.status, item?.bookingStatus),
        startDate: text(item?.startDate, item?.departureDate, item?.checkInDate),
        endDate: text(item?.endDate, item?.returnDate, item?.checkOutDate),
        destination: text(item?.destinationName, item?.destination, item?.location),
    });
    const segment = (item) => ({
        type: text(item?.segmentType, item?.type, item?.productType),
        title: text(item?.title, item?.name, item?.description),
        origin: text(item?.originName, item?.origin, item?.from),
        destination: text(item?.destinationName, item?.destination, item?.to),
        startDate: text(item?.startDate, item?.departureDate, item?.checkInDate),
        endDate: text(item?.endDate, item?.arrivalDate, item?.checkOutDate),
        status: text(item?.status, item?.bookingStatus),
        confirmationNumber: text(item?.confirmationNumber, item?.confirmation_number, item?.recordLocator),
    });

    // Booking results are a separate application. Use its observed public route,
    // not reconstructed OAuth payloads or the legacy prebooking redirect.
    const testNode = (root, id) => root.querySelector('[data-testid="' + id + '"]');
    const nodeText = (root, id) => (testNode(root,id)?.innerText || '').trim();
    const money = root => {
        const priceRoot = testNode(root, 'departure-selection-flight-total-price');
        const prices = priceRoot ? [...priceRoot.querySelectorAll('[data-testid="flight-average-price"]')].map(e => e.innerText.trim()).filter(s => /^\$/.test(s)) : [];
        const s = prices[prices.length-1];
        return s ? Number(s.replace(/[^0-9.]/g,'')) : null;
    };
    const flightFields = card => {
        const airlineEl = card.querySelector('[data-testid$="-airline-code"]');
        const airport = suffix => (card.querySelector('[data-testid$="'+suffix+'"]')?.innerText || '').trim();
        const item = {
            airline:(airlineEl?.innerText || '').trim(),
            departureTime:nodeText(card,'departure-date'), arrivalTime:nodeText(card,'arrival-data'),
            origin:airport('-departure-airport-code'),destination:airport('-arrival-airport-code'),
            duration:nodeText(card,'offer-card-flight-duration'),stops:nodeText(card,'offer-card-stop'),
            priceFrom:money(card),currency:'USD',priceBasis:'Starting roundtrip total; return not selected',
            fareOptionsLabel:nodeText(card,'offer-card-select-fare-button')
        };
        return {flightKey:[item.airline,item.departureTime,item.arrivalTime,item.origin,item.destination].join('|'),...item};
    };
    const readyFlightCards = async args => {
        if(location.hostname !== 'www.travel.americanexpress.com') throw Error('Use a fresh booking-app session discovered on www.travel.americanexpress.com for flight searches');
        const desired = new URLSearchParams({adults:String(args.adults),cabinClass:args.cabinClass,children:'0',childrenAges:'',departureDate:args.departureDate,destinationId:args.destinationId,destinationLocationType:args.destinationType,destinationName:args.destination,destinationValue:args.destination,inLapInfants:'0',inSeatInfants:'0',originId:args.originId,originLocationType:args.originType,originName:args.origin,originValue:args.origin,page:'1',pageSize:'50',returnDate:args.returnDate,type:'ROUND_TRIP'});
        const current=new URLSearchParams(location.search);
        const matches=location.pathname==='/en-us/book/flights/search-results' && [...desired].every(([k,v])=>current.get(k)===v);
        let previousCard=null;
        if(!matches) {
            previousCard=document.querySelector('[data-testid="offer-card-wrapper"]');
            const deadline=Date.now()+10000;
            while(Date.now()<deadline&&!window.next?.router?.isReady) await new Promise(r=>setTimeout(r,100));
            if(typeof window.next?.router?.push!=='function') throw Error('Booking client router unavailable; pass the public results URL as pageUrl');
            await window.next.router.push('/flights/search-results?'+desired.toString());
        }
        const q=new URLSearchParams(location.search);
        for(const [key,value] of Object.entries({originValue:args.origin,destinationValue:args.destination,departureDate:args.departureDate,returnDate:args.returnDate,adults:String(args.adults),cabinClass:args.cabinClass})) {
            if(q.get(key)!==value) throw Error('Flight search context mismatch: '+key);
        }
        if(args.returnDate<args.departureDate) throw Error('Return date precedes departure date');
        const deadline=Date.now()+45000;
        while(Date.now()<deadline) {
            if(location.pathname!=='/en-us/book/flights/search-results') throw Error('Flight results redirected to '+location.pathname+'; booking session may require login');
            const cards=[...document.querySelectorAll('[data-testid="offer-card-wrapper"]')];
            if(cards.length && (!previousCard || !previousCard.isConnected) && cards.every(c=>nodeText(c,'departure-date'))) return cards;
            const message=(document.body?.innerText || '');
            if(/verify you are human|access denied|security check/i.test(message)) throw Error('Website verification requires user review');
            if(/no flights found|no flights available|no results found/i.test(message)) return [];
            await new Promise(r=>setTimeout(r,200));
        }
        throw Error('Flight results did not finish loading within 45 seconds; no fares verified');
    };
    action('listFlightOffers',{async invoke(args){
        const cards=await readyFlightCards(args);
        const label=nodeText(document,'pagination-results-text');
        const match=label.match(/viewing\s+([\d,]+)\s+out of\s+([\d,]+)/i);
        const totalCount=match?Number(match[2].replace(/,/g,'')):null;
        const filtered=cards.map(flightFields).filter(f=>!args.airline||f.airline.toLowerCase().includes(args.airline.toLowerCase()));
        return {items:filtered.slice(0,args.limit),nextCursor:null,loadedCount:cards.length,totalCount,
            coverage:totalCount!==null&&totalCount===cards.length&&filtered.length<=args.limit?'complete':'partial',
            sourceUrl:location.origin+location.pathname+location.search};
    }});
    action('getFlightFareOptions',{async invoke(args){
        const cards=await readyFlightCards(args);
        const card=cards.find(c=>flightFields(c).flightKey===args.flightKey);
        if(!card) throw Error('Requested flight is not in loaded search results; refresh search');
        if(!testNode(card,'fare-options')) {
            const button=testNode(card,'offer-card-select-fare-button');
            if(!button || !/View.*Fare Options/i.test(button.innerText)) throw Error('Read-only fare expansion unavailable');
            button.click();
        }
        const deadline=Date.now()+12000;
        while(Date.now()<deadline&&!card.querySelector('[data-testid="fare-brand-container"]')) await new Promise(r=>setTimeout(r,150));
        const brands=[...card.querySelectorAll('[data-testid="fare-brand-container"]')];
        if(!brands.length) throw Error('Fare options did not load');
        return {flightKey:args.flightKey,items:brands.map(b=>({name:nodeText(b,'fare-brand-name'),price:money(b),currency:'USD',priceBasis:'Starting roundtrip total; return not selected',features:[...b.querySelectorAll('[data-testid="fare-feature-item"]')].map(e=>[...new Set(e.innerText.split('\n').map(s=>s.trim()).filter(Boolean))].join('; '))})),nextCursor:null,returnFlightSelected:false};
    }});

    let profileIdCache = null;
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
const loginStep = async () => waitForStep({challenge:()=>document.querySelector('input[autocomplete="one-time-code"], iframe[src*="captcha"]') || (/security check|verify you are human|enter.{0,20}(verification|security) code/i.test(document.body?.innerText||'') ? document.body : null),credentials:()=>{if(!location.pathname.includes('/account/login'))return null;const username=document.getElementById('eliloUserID'),password=document.getElementById('eliloPassword'),submit=document.getElementById('loginSubmit');return usable(username)&&usable(password)&&usable(submit)&&username.closest('form')?.contains(password)&&username.closest('form')?.contains(submit)?{username,password,submit,form:username.closest('form')}:null;},signedIn:()=>!location.pathname.includes('/account/login')&&document.getElementById('gnav_logout')});
    action('login', { async invoke(input, context) {
        const step=await loginStep();
        if(step.kind==='unknown') throw Error('Amex sign-in screen not recognized; automatic login stopped.');
        if(step.kind!=='credentials') return null;
        if(!input?.account || input.account.serviceID!=='web:americanexpress.com') return null;
        if(pageError(step.match.form)) throw Error('Amex sign-in form reports an error; automatic login stopped without retrying.');
        const account=await context.secret(input.account);
        typeInto(step.match.username,account.username);
        typeInto(step.match.password,account.password);
        if(!usable(step.match.submit)) throw Error('Amex login button is unavailable.');
        step.match.submit.click();
        return null;
    }});
    action('listSessions', { async invoke() {
            profileIdCache = null;
            if (location.hostname === 'global.americanexpress.com') {
                const deadline=Date.now()+15000;
                while(Date.now()<deadline){
                    if(document.getElementById('loginSubmit')||document.getElementById('eliloUserID'))return [];
                    const h=[...document.querySelectorAll('main h1,main h2')].find(e=>/[0-9]{4,5}/.test(e.textContent)&&/Card/.test(e.textContent));
                    const control=document.getElementById('myca-feed-search');
                    if(h&&control&&document.getElementById('gnav_logout')){const label=h.textContent.replace(/\s+/g,' ').trim();return [{id:'card:'+label,label,url:'https://global.americanexpress.com/activity'}];}
                    if(/unable to display|try again later/i.test(document.querySelector('main')?.innerText||''))throw Error('Account activity is unavailable; authentication not determined.');
                    await new Promise(resolve=>setTimeout(resolve,150));
                }
                throw Error('Account identity and activity controls not ready; authentication not determined.');
            }

            // The newer booking origin cannot use the legacy functions/apigw
            // discovery calls (CORS). Confirm its own live session instead.
            if (location.hostname === 'www.travel.americanexpress.com') {
                const response = await fetch('/en-us/book/api/auth/session', {credentials:'include',cache:'no-store'});
                if (!response.ok) throw Error('Booking session HTTP '+response.status);
                const booking = await response.json();
                if (booking && Object.keys(booking).length === 0) return [];
                if (!booking?.userId || !booking?.expires || Date.parse(booking.expires) <= Date.now()) throw Error('Booking session identity unavailable or expired');
                return [{id:'booking:'+String(booking.userId),label:'American Express Travel booking',url:'https://www.travel.americanexpress.com/en-us/book/flights/search-results'}];
            }
            const session = await fetch('https://functions.americanexpress.com/ReadUserSession.v1', {
                credentials: 'include',
                cache: 'no-store',
            });
            if (session.status === 400) {
                const error = await session.json();
                if (error?.errorCode === 'IDENT01'
                    && error.description === 'Must provide user JWT after "aat=" under header key "Cookie"')
                    return [];
            }
            if (!session.ok)
                throw Error('American Express session HTTP ' + session.status);
            const j = await fetchProfile();
            if (!j?.profile_id)
                throw Error('American Express profile identity unavailable');
            return [{ id: String(j.profile_id), label: 'American Express ' + String(j.profile_id), url: ORIGIN + '/en-us/account/summary' }];
        } });
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
                console.log(`getProfile: profileId=${j?.profile_id ?? "?"} cards=${cards.length}`);
                return {
                    profileId: j?.profile_id ?? null,
                    name: name || null,
                    cardsCount: cards.length,
                };
            }
            catch (e) {
                console.log("getProfile: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });
    action("listLoyalties", {
        async invoke() {
            try {
                const id = await profileId();
                if (!id)
                    throw new Error("no profileId available");
                const j = await call(`/profile_mgmt/profiles/${id}/primary_traveler/loyalties`, profileHeaders());
                const items = firstArray(j, ["loyalties"]).map(loyalty);
                console.log(`listLoyalties: ${items.length} programs`);
                return { items, nextCursor: null };
            }
            catch (e) {
                console.log("listLoyalties: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });
    action("listTrips", {
        async invoke({ tripType } = {}) {
            try {
                const type = (tripType ?? "upcoming").toLowerCase();
                const j = await call(`/bookings/summary?type=${type}`, bookingHeaders(), {
                    method: "POST",
                    headers: { "content-type": "application/json" },
                    body: JSON.stringify({}),
                });
                const items = firstArray(j, ["bookings", "trips", "summary", "items", "results"]).map(trip);
                console.log(`listTrips: ${items.length} trips (${type})`);
                return { items, nextCursor: null };
            }
            catch (e) {
                console.log("listTrips: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });
    action("getTrip", {
        async invoke({ tripId, bookingDate }) {
            try {
                const j = await call("/bookings/details", bookingHeaders(), {
                    method: "POST",
                    headers: { "content-type": "application/json" },
                    body: JSON.stringify({ tripId, bookingDate }),
                });
                console.log(`getTrip: tripId=${tripId} keys=${Object.keys(j ?? {}).join(",")}`);
                return {
                    ...trip({ ...j, tripId, bookingDate }),
                    travelers: firstArray(j, ["travelers", "passengers"]).map((traveler) => text(traveler?.fullName, traveler?.name, traveler?.travelerName)).filter((name) => name !== null),
                    segments: firstArray(j, ["segments", "flights", "hotels", "cars", "items"]).map(segment),
                };
            }
            catch (e) {
                console.log("getTrip: " + (e?.message ?? String(e)));
                throw e;
            }
        },
    });

    action('searchFlightLocations',{async invoke(args){
        if(location.hostname!=='www.travel.americanexpress.com')throw Error('Booking app context required');
        const r=await fetch('/en-us/book/api/lxp/air/smartfill?query='+encodeURIComponent(args.query),{credentials:'include'});
        if(!r.ok)throw Error('Airport smartfill HTTP '+r.status);const j=await r.json();
        if(!Array.isArray(j.airports)||!Array.isArray(j.cities))throw Error('Airport lookup response incomplete');
        const items=[...j.airports.map(x=>({id:x.id,code:x.code,name:x.name,city:x.cityName||'',type:x.isMetropolitanArea?'CITY_CODE':'AIRPORT_CODE'})),...j.cities.map(x=>({id:x.id,code:x.iataCode||'',name:x.name,city:x.name,type:'CITY_CODE'}))];
        return {items:items.slice(0,args.limit||20),nextCursor:null};
    }});

    action('listAnnualMembershipFees',{async invoke(args){
        const visible=e=>{const r=e.getBoundingClientRect();return r.width>0&&r.height>0;};
        const norm=s=>String(s||'').replace(/\s+/g,' ').trim().toLowerCase();
        const wait=async(fn,ms=12000)=>{const end=Date.now()+ms;while(Date.now()<end){const v=fn();if(v)return v;await new Promise(r=>setTimeout(r,150));}throw Error('Card activity controls or filtered results did not become ready.');};
        await wait(()=>document.getElementById('myca-feed-search'));
        const headings=[...document.querySelectorAll('main h1,main h2')].map(e=>e.textContent).join(' ');
        if(!headings.toLowerCase().includes(args.cardName.toLowerCase())||!headings.includes(args.lastDigits))throw Error('Selected card does not match requested card; select the correct card first.');
        const dismiss=[...document.querySelectorAll('button')].find(e=>visible(e)&&norm(e.innerText)==='explore on my own');dismiss?.click();
        const range=document.querySelector('[data-testid="date-picker-popover-button"]');if(!range)throw Error('Activity date range control missing');
        const expected=String(args.year);if(!norm(range.innerText).startsWith(expected)){
            range.click();const option=await wait(()=>[...document.querySelectorAll('button')].find(e=>visible(e)&&(norm(e.innerText)===expected||norm(e.innerText).startsWith(expected+' year'))));option.click();
            await wait(()=>{const b=document.querySelector('[data-testid="date-picker-popover-button"]');return b&&norm(b.innerText).startsWith(expected)&&document.getElementById('myca-feed-search');});
        }
        const input=document.getElementById('myca-feed-search');input.focus();Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(input,'MEMBERSHIP');input.dispatchEvent(new Event('input',{bubbles:true}));
        const search=await wait(()=>[...document.querySelectorAll('main button')].find(e=>visible(e)&&norm(e.innerText)==='search'));search.click();
        const rows=await wait(()=>{const rows=[...document.querySelectorAll('[data-testid="activity-feed-transaction-row"]')];return rows.length&&rows.every(e=>/membership/i.test(e.innerText))?rows:null;});
        const items=rows.slice(0,args.limit||10).map(row=>{const cells=[...row.querySelectorAll('td')];if(cells.length<4)throw Error('Fee row incomplete');const label=cells[0].querySelector('.DataTable_module_cellTextTruncate')?.textContent.trim()||'';const description=cells[2].textContent.trim();const raw=cells.at(-1).textContent.trim();const amount=Number(raw.replace(/[^0-9.-]/g,''));if(!label||!Number.isFinite(amount))throw Error('Fee date or amount missing');return {dateLabel:label+', '+args.year,description,amount,currency:'USD'};});
        return {cardName:args.cardName,lastDigits:args.lastDigits,year:args.year,items,nextCursor:null,coverage:'partial',futureRenewalConfirmed:false};
    }});
});
