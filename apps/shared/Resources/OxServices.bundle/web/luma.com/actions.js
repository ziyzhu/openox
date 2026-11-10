
async function discoverAuthenticatedSessions(){const r=await fetch('https://luma.com/home',{credentials:'include',cache:'no-store'});if(r.status===401)return [];if(!r.ok)throw Error('Luma identity HTTP '+r.status);const doc=new DOMParser().parseFromString(await r.text(),'text/html');const node=doc.getElementById('__NEXT_DATA__');if(!node)throw Error('Luma bootstrap identity missing');const p=JSON.parse(node.textContent).props;if(!p||!Object.prototype.hasOwnProperty.call(p,'initialUserData'))throw Error('Unclassified Luma bootstrap');const u=p.initialUserData?.user;if(u&&typeof u.api_id==='string'&&u.api_id&&typeof u.name==='string')return [{id:u.api_id,label:u.name,url:'https://luma.com/home'}];if(p.initialUserData===null)return [];throw Error('Unclassified Luma identity');}
const cleanText = value => String(value ?? '').replace(/\s+/g, ' ').trim();

const lumaHeaders = pageUrl => ({
  'accept-language': 'en',
  'x-luma-client-type': 'luma-web',
  'x-luma-web-url': pageUrl,
  'x-luma-timezone': 'America/Los_Angeles',
});

const eventItem = entry => {
  const event = entry?.event ?? {};
  const address = event?.geo_address_info;
  const location = address?.full_address || address?.address || address?.city_state || null;
  const slug = cleanText(event?.url);
  if (!slug || !cleanText(event?.name) || !cleanText(event?.start_at)) throw new Error('Luma returned an incomplete event');
  return {
    title: cleanText(event.name),
    startAt: cleanText(event.start_at),
    endAt: event.end_at ? cleanText(event.end_at) : null,
    timezone: cleanText(event.timezone || 'America/Los_Angeles'),
    location,
    registrationStatus: entry.registration_availability ? cleanText(entry.registration_availability) : null,
    waitlistActive: Boolean(entry.waitlist_active),
    attendanceStatus: entry.guest_info?.approval_status ? cleanText(entry.guest_info.approval_status) : null,
    eventUrl: 'https://luma.com/' + encodeURIComponent(slug),
  };
};

const readEvents = async (endpoint, pageUrl) => {
  const response = await fetch(endpoint, { credentials: 'include', headers: lumaHeaders(pageUrl) });
  if (response.status === 401 || response.status === 403) throw new Error('Luma sign-in is required');
  if (!response.ok) throw new Error(`Luma events request failed (HTTP ${response.status})`);
  const data = await response.json();
  if (!Array.isArray(data?.entries)) throw new Error('Luma events response had an unexpected shape');
  return { items: data.entries.map(eventItem), nextCursor: data.has_more && typeof data.next_cursor === 'string' ? data.next_cursor : null };
};


async function readRegistrationEvent(eventUrl){
 const u=new URL(eventUrl);if(u.origin!=='https://luma.com'||u.pathname.split('/').filter(Boolean).length!==1)throw Error('Expected a direct Luma event URL');
 const r=await fetch(u.href,{credentials:'include',cache:'no-store'});if(!r.ok)throw Error('Registration state HTTP '+r.status);
 const doc=new DOMParser().parseFromString(await r.text(),'text/html');const n=doc.getElementById('__NEXT_DATA__');if(!n)throw Error('Registration bootstrap missing');const p=JSON.parse(n.textContent).props;const initial=p.pageProps?.initialData;if(initial?.kind!=='event')throw Error('Expected event bootstrap');const d=initial.data;if(!d?.event?.name)throw Error('Event identity missing');return d;
}
const registrationStatus=d=>d.guest_data?.approval_status||d.guest_info?.approval_status||null;

window.ox.install(({ action }) => {
 action('getRegistration',{async invoke(args){const d=await readRegistrationEvent(args.eventUrl);return {title:d.event.name,url:args.eventUrl,status:registrationStatus(d)||'not_registered',details:d.registration_availability||'unknown'};}});
 action('registerFreeEvent',{async invoke(args){
  const u=new URL(args.eventUrl);if(location.origin!==u.origin||location.pathname.replace(/\/$/,'')!==u.pathname.replace(/\/$/,''))throw Error('Invoke on the exact requested event page');
  const d=await readRegistrationEvent(args.eventUrl);if(d.event.name!==args.expectedTitle)throw Error('Event title does not match requested target');
  const status=registrationStatus(d);if(status)return {title:d.event.name,url:args.eventUrl,status,details:'Existing registration state; no submission made'};
  if(d.ticket_info?.is_free!==true||!Array.isArray(d.ticket_types)||d.ticket_types.some(t=>!t.is_disabled&&!t.is_hidden&&t.type!=='free'))throw Error('Only verified free registrations supported');
  if(d.registration_questions?.length)throw Error('Registration has custom questions requiring preparation');
  if(d.registration_availability!=='open')throw Error('Registration is not open: '+d.registration_availability);
  const deadline=Date.now()+10000;let buttons=[];while(Date.now()<deadline){buttons=[...document.querySelectorAll('button')].filter(b=>cleanText(b.textContent)==='One-Click RSVP'&&!b.disabled);if(buttons.length===1)break;await new Promise(r=>setTimeout(r,150));}
  if(buttons.length!==1)throw Error('Unique One-Click RSVP control unavailable; nothing submitted');
  buttons[0].click();
  const finish=Date.now()+15000;while(Date.now()<finish){await new Promise(r=>setTimeout(r,600));const after=await readRegistrationEvent(args.eventUrl);const current=registrationStatus(after);if(current)return {title:after.event.name,url:args.eventUrl,status:current,details:'Verified from fresh signed-in event state'};}
  return {title:d.event.name,url:args.eventUrl,status:'uncertain',details:'RSVP clicked once; no server-confirmed outcome observed. Inspect before any retry'};
 }});

action('getEvent',{async invoke(args){
const u=new URL(args.url);if(u.protocol!=='https:'||u.hostname!=='luma.com')throw Error('Expected a Luma event URL');
const r=await fetch(u.href,{credentials:'omit'});if(!r.ok)throw Error('Event HTTP '+r.status);
const doc=new DOMParser().parseFromString(await r.text(),'text/html');
const n=doc.getElementById('__NEXT_DATA__');if(!n)throw Error('Event bootstrap missing');const d=JSON.parse(n.textContent).props?.pageProps?.initialData;if(d?.kind!=='event')throw Error('Not an event page');const e=d.data?.event;if(!e?.name||!e.start_at||!e.end_at)throw Error('Event details incomplete');const text=n=>n?.text||(n?.content||[]).map(text).join(n?.type==='doc'?'\n':'');return {title:e.name,start:e.start_at,end:e.end_at,location:e.geo_address_info?.full_address||'',description:text(d.data.description_mirror),url:'https://luma.com/'+e.url};
}});
action('listSessions',{async invoke(){return discoverAuthenticatedSessions();}});
action('login',{async invoke(){return null;}});
  action('listSeattleEvents', {
    async invoke(args) {
      const limit = Math.max(1, Math.min(50, Number.parseInt(args.limit ?? 20, 10) || 20));
      const endpoint = new URL('https://api.luma.com/discover/get-paginated-events');
      endpoint.searchParams.set('discover_place_api_id', 'discplace-FQ4E58PeBMHGTKK');
      endpoint.searchParams.set('pagination_limit', String(limit));
      const result = await readEvents(endpoint, 'https://luma.com/seattle');
      console.log('listSeattleEvents', { count: result.items.length, hasMore: Boolean(result.nextCursor) });
      return result;
    },
  });

  action('listMyEvents', {
    async invoke(args) {
      const limit = Math.max(1, Math.min(50, Number.parseInt(args.limit ?? 25, 10) || 25));
      const period = args.period === 'upcoming' ? 'future' : 'past';
      const endpoint = new URL('https://api.luma.com/home/get-events');
      endpoint.searchParams.set('pagination_limit', String(limit));
      endpoint.searchParams.set('period', period);
      const result = await readEvents(endpoint, 'https://luma.com/home');
      console.log('listMyEvents', { period, count: result.items.length, hasMore: Boolean(result.nextCursor) });
      return result;
    },
  });


});
