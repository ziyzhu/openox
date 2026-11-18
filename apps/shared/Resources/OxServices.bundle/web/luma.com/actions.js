function createEmbeddedAutomation({ timeout = 5000 } = {}) {
  const normalize = value => String(value ?? "").replace(/\s+/g, " ").trim();
  const matches = (actual, expected, exact = false) => exact
    ? normalize(actual) === normalize(expected)
    : normalize(actual).toLowerCase().includes(normalize(expected).toLowerCase());
  const visible = element => {
    if (!element.isConnected || element.closest('[hidden], [inert], [aria-hidden="true"]')) return false;
    for (let node = element; node?.nodeType === 1; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse") return false;
    }
    return element.getClientRects().length > 0;
  };
  const disabled = element => element.matches(":disabled") || !!element.closest('[aria-disabled="true"], [inert]');
  const label = element => {
    const ids = element.getAttribute("aria-labelledby");
    if (ids) {
      const text = normalize(ids.split(/\s+/).map(id => element.ownerDocument.getElementById(id)?.textContent ?? "").join(" "));
      if (text) return text;
    }
    if (element.hasAttribute("aria-label")) return normalize(element.getAttribute("aria-label"));
    if (element.labels?.length) return normalize(Array.from(element.labels, item => item.textContent).join(" "));
    if (element.tagName === "IMG") return normalize(element.getAttribute("alt"));
    if (element.tagName === "INPUT" && ["submit", "reset", "button"].includes(element.type)) return normalize(element.value);
    return normalize(element.getAttribute("title") || (["INPUT", "TEXTAREA", "SELECT"].includes(element.tagName) ? "" : element.textContent));
  };
  const role = element => {
    const explicit = element.getAttribute("role")?.trim().split(/\s+/)[0];
    if (explicit) return explicit;
    const tag = element.tagName;
    if (tag === "INPUT") {
      const type = element.type;
      if (["button", "submit", "reset", "image"].includes(type)) return "button";
      if (["checkbox", "radio"].includes(type)) return type;
      if (type === "range") return "slider";
      if (type === "number") return "spinbutton";
      if (type === "search") return "searchbox";
      if (["text", "email", "tel", "url"].includes(type)) return "textbox";
      return "";
    }
    if (tag === "A") return element.hasAttribute("href") ? "link" : "";
    if (tag === "SELECT") return element.multiple || element.size > 1 ? "listbox" : "combobox";
    if (/^H[1-6]$/.test(tag)) return "heading";
    return ({ BUTTON: "button", TEXTAREA: "textbox", OPTION: "option", IMG: "img", UL: "list", OL: "list", LI: "listitem", TABLE: "table", TR: "row", TD: "cell", TH: "columnheader", DIALOG: "dialog", MAIN: "main", NAV: "navigation" })[tag] ?? "";
  };
  const duration = value => {
    const ms = value ?? timeout;
    if (!Number.isFinite(ms) || ms < 0 || ms > 30000) throw new Error("Automation timeout must be between 0 and 30000 ms");
    return ms;
  };
  duration(timeout);
  const pause = () => new Promise(resolve => setTimeout(resolve, 25));
  const locator = (resolve, description) => {
    const unique = () => {
      const elements = resolve();
      if (elements.length > 1) throw new Error(`Strict locator matched ${elements.length} elements: ${description}`);
      return elements[0];
    };
    const wait = async (predicate, options = {}) => {
      const deadline = Date.now() + duration(options.timeout);
      for (;;) {
        const element = unique();
        if (predicate(element)) return element;
        if (Date.now() >= deadline) throw new Error(`Locator condition timed out: ${description}`);
        await pause();
      }
    };
    const actionable = options => wait(element => element && visible(element) && !disabled(element), options);
    const clickElement = element => {
      element.scrollIntoView({ block: "center", inline: "center" });
      const rect = element.getBoundingClientRect();
      const hit = element.ownerDocument.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
      if (!hit || hit !== element && !element.contains(hit)) throw new Error(`Locator is obscured: ${description}`);
      if (!element.isConnected || disabled(element)) throw new Error(`Locator became unavailable: ${description}`);
      element.click();
    };
    const api = {
      ...queries(() => resolve()),
      filter({ hasText }) {
        if (typeof hasText !== "string") throw new Error("filter requires a string hasText");
        return locator(() => resolve().filter(element => matches(element.textContent, hasText)), `${description}.filter`);
      },
      nth(index) {
        if (!Number.isSafeInteger(index) || index < 0) throw new Error("nth requires a nonnegative integer");
        return locator(() => resolve().slice(index, index + 1), `${description}.nth(${index})`);
      },
      first() { return api.nth(0); },
      last() { return locator(() => resolve().slice(-1), `${description}.last()`); },
      async count() { return resolve().length; },
      async isVisible() { const element = unique(); return !!element && visible(element); },
      async waitFor({ state = "visible", ...options } = {}) {
        if (!["attached", "detached", "visible", "hidden"].includes(state)) throw new Error("Unsupported locator state");
        await wait(element => state === "attached" ? !!element : state === "detached" ? !element : state === "visible" ? !!element && visible(element) : !element || !visible(element), options);
      },
      async innerText(options) { return (await wait(element => !!element, options)).innerText; },
      async textContent(options) { return (await wait(element => !!element, options)).textContent; },
      async getAttribute(name, options) { return (await wait(element => !!element, options)).getAttribute(name); },
      async allTextContents() { return resolve().map(element => element.textContent ?? ""); },
      async click(options) { clickElement(await actionable(options)); },
      async fill(value, options) {
        if (typeof value !== "string") throw new Error("fill requires a string");
        const element = await actionable(options);
        if (element.readOnly) throw new Error(`Locator is read-only: ${description}`);
        if (element.tagName === "INPUT" && !["text", "email", "password", "search", "tel", "url", "number"].includes(element.type)) throw new Error("Unsupported input type for fill");
        const view = element.ownerDocument.defaultView;
        const prototype = element.tagName === "INPUT" ? view.HTMLInputElement.prototype : element.tagName === "TEXTAREA" ? view.HTMLTextAreaElement.prototype : null;
        element.focus();
        if (prototype) Object.getOwnPropertyDescriptor(prototype, "value").set.call(element, value);
        else if (element.isContentEditable) element.textContent = value;
        else throw new Error("fill requires an input, textarea, or contenteditable element");
        element.dispatchEvent(new view.Event("input", { bubbles: true }));
        element.dispatchEvent(new view.Event("change", { bubbles: true }));
      },
      async check(options) { await api.setChecked(true, options); },
      async uncheck(options) { await api.setChecked(false, options); },
      async setChecked(checked, options) {
        if (typeof checked !== "boolean") throw new Error("setChecked requires a boolean");
        const element = await actionable(options);
        if (element.tagName !== "INPUT" || !["checkbox", "radio"].includes(element.type)) throw new Error("setChecked requires a checkbox or radio input");
        if (element.checked === checked) return;
        clickElement(element);
        if (element.checked !== checked) throw new Error("Checked state unverified after dispatch; inspect before retrying");
      },
      async selectOption(value, options) {
        const values = Array.isArray(value) ? value : [value];
        if (values.some(item => typeof item !== "string")) throw new Error("selectOption accepts string values only");
        const element = await actionable(options);
        if (element.tagName !== "SELECT" || !element.multiple && values.length !== 1) throw new Error("Invalid selectOption target or values");
        const selected = Array.from(element.options).filter(option => values.includes(option.value));
        if (values.some(value => !selected.some(option => option.value === value)) || selected.some(option => option.disabled || option.parentElement?.disabled)) throw new Error("Select option is missing or disabled");
        for (const option of element.options) option.selected = values.includes(option.value);
        const view = element.ownerDocument.defaultView;
        element.dispatchEvent(new view.Event("input", { bubbles: true }));
        element.dispatchEvent(new view.Event("change", { bubbles: true }));
        return selected.map(option => option.value);
      },
    };
    return api;
  };
  function queries(roots) {
    const find = predicate => [...new Set(roots().flatMap(root => Array.from(root.querySelectorAll("*"))))].filter(predicate);
    return {
      locator(selector) { return locator(() => [...new Set(roots().flatMap(root => Array.from(root.querySelectorAll(selector))))], "css locator"); },
      getByRole(expected, { name, exact = false, includeHidden = false } = {}) {
        return locator(() => find(element => role(element) === expected && (includeHidden || visible(element)) && (name === undefined || matches(label(element), name, exact))), `role=${expected}`);
      },
      getByLabel(text, { exact = false } = {}) {
        return locator(() => find(element => element.matches("input, textarea, select, button, [contenteditable], [aria-label], [aria-labelledby]") && matches(label(element), text, exact)), "label locator");
      },
      getByText(text, { exact = false } = {}) {
        return locator(() => find(element => !element.matches("script, style, head, title") && matches(element.textContent, text, exact)
          && !Array.from(element.children).some(child => matches(child.textContent, text, exact))), "text locator");
      },
      getByPlaceholder(text, { exact = false } = {}) {
        return locator(() => find(element => element.hasAttribute("placeholder") && matches(element.getAttribute("placeholder"), text, exact)), "placeholder locator");
      },
      getByTestId(value) { return locator(() => find(element => element.getAttribute("data-testid") === value), "test id locator"); },
    };
  }
  return queries(() => [document]);
}


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


function registrationSurface(d){const root=document.querySelector('[role="dialog"] form')||document.querySelector('form.registration-form-container');return {title:d.event.name,url:location.href,status:registrationStatus(d)||'not_registered',isFree:d.ticket_info?.is_free===true,questions:(d.registration_questions||[]).map(q=>({label:q.label,type:q.question_type,required:!!q.required,options:q.options||[]})),formText:(root?.innerText||'').slice(0,9000),controls:root?[...root.querySelectorAll('input:not([type="hidden"]),textarea:not([aria-hidden="true"]),select,button')].map(e=>({tag:e.tagName,type:e.type||'',name:e.name||'',label:e.labels?.[0]?.textContent?.trim()||e.getAttribute('aria-label')||document.getElementById(e.getAttribute('aria-labelledby'))?.textContent?.trim()||e.textContent?.trim().slice(0,180)||'',required:!!e.required,hasValue:!!e.value})):[]};}

window.ox.install(({ action }) => {
 const page=createEmbeddedAutomation({timeout:7000});

 action('fillRegistrationDetails',{async invoke(args){const d=await readRegistrationEvent(location.href);if(d.event.name!==args.expectedTitle)throw Error('Event identity mismatch');const root=page.locator('[role="dialog"] form');if(!document.querySelector('[role="dialog"] form'))throw Error('Prepare the registration dialog first');await root.getByText('Your Info',{exact:true}).click();for(const f of args.fields)await root.getByLabel(f.label,{exact:false}).fill(f.value);for(const multi of args.multis){const group=root.locator('.lux-input-wrapper').filter({hasText:multi.label});await group.locator('div[id$="-value"]').click();for(const value of multi.values){const option=page.getByRole('option',{name:value,exact:true});if(await option.getAttribute('aria-selected')!=='true')await option.click();}await root.getByText('Your Info',{exact:true}).click();}return registrationSurface(d);}});
 action('getRegistrationForm',{async invoke(){const d=await readRegistrationEvent(location.href);return registrationSurface(d);}});
 action('prepareRegistration',{async invoke(){const d=await readRegistrationEvent(location.href);if(registrationStatus(d))return registrationSurface(d);if(!document.querySelector('[role="dialog"] form')){const candidates=[...document.querySelectorAll('button')].filter(b=>['Request to Join','Get Ticket','Get Tickets','Register','Register Now'].includes(cleanText(b.textContent))&&!b.disabled);if(candidates.length!==1)throw Error('Unique registration preparation control unavailable');const label=cleanText(candidates[0].textContent);await page.getByRole('button',{name:label,exact:true}).click();}const end=Date.now()+8000;while(Date.now()<end&&!document.querySelector('[role="dialog"] form'))await new Promise(r=>setTimeout(r,100));return registrationSurface(d);}});
 action('submitFreeForm',{async invoke(args){const d=await readRegistrationEvent(location.href);if(d.event.name!==args.expectedTitle)throw Error('Event title mismatch');const before=registrationStatus(d);if(before)return {title:d.event.name,url:location.href,status:before,details:'Existing registration; no submission made'};if(d.ticket_info?.is_free!==true)throw Error('Paid registrations require payment review');const form=document.querySelector('[role="dialog"] form');if(!form)throw Error('Prepare registration form first');for(const field of args.fields){await page.locator('[role="dialog"] form').getByLabel(field.label,{exact:false}).fill(field.value);}for(const choice of (args.selections||[])){await page.locator('[role="dialog"] form').getByRole('combobox',{name:choice.label,exact:false}).click();await page.getByRole('option',{name:choice.value,exact:true}).click();}if(!form.checkValidity())throw Error('Required registration fields are incomplete');const button=[...form.querySelectorAll('button[type="submit"]')].filter(b=>cleanText(b.textContent)==='Request to Join'&&!b.disabled);if(button.length!==1)throw Error('Unique request submission unavailable');await page.locator('[role="dialog"] form').getByRole('button',{name:'Request to Join',exact:true}).click();const end=Date.now()+15000;while(Date.now()<end){await new Promise(r=>setTimeout(r,650));const fresh=await readRegistrationEvent(location.href);const status=registrationStatus(fresh);if(status)return {title:fresh.event.name,url:location.href,status,details:'Fresh server registration state verified'};}return {title:d.event.name,url:location.href,status:'uncertain',details:'Submitted once; inspect state before retrying'};}});

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
