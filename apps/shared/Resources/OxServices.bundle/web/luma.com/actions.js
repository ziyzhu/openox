
async function discoverAuthenticatedSessions(){const r=await fetch('https://luma.com/home',{credentials:'include',cache:'no-store'});if(r.status===401)return [];if(!r.ok)throw Error('Luma identity HTTP '+r.status);const doc=new DOMParser().parseFromString(await r.text(),'text/html');const node=doc.getElementById('__NEXT_DATA__');if(!node)throw Error('Luma bootstrap identity missing');const p=JSON.parse(node.textContent).props;if(!p||!Object.prototype.hasOwnProperty.call(p,'initialUserData'))throw Error('Unclassified Luma bootstrap');const u=p.initialUserData?.user;if(u&&typeof u.api_id==='string'&&u.api_id&&typeof u.name==='string')return [{id:u.api_id,label:u.name,url:'https://luma.com/home'}];if(p.initialUserData===null)return [];throw Error('Unclassified Luma identity');}
async function assertSelectedAccount(context){const list=await discoverAuthenticatedSessions();if(!context?.session||!list.some(s=>s.id===context.session.id))throw Error('Selected account is unavailable or changed; rediscover sessions');}
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

window.ox.install(({ action: registerAction }) => {
const protectedActionIds=new Set(["listMyEvents"]);
const action=(id,handler)=>registerAction(id,protectedActionIds.has(id)?{...handler,async invoke(args,context){await assertSelectedAccount(context);return handler.invoke(args,context);}}:handler);
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
